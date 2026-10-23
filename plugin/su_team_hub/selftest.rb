# Two-window end-to-end test. Only active when the TEAMHUB_SELFTEST environment
# variable points to a JSON script; never runs in normal use and never writes
# the user's saved Team Hub settings. Bot "A" shares a file, bot "B" downloads
# it; they then move, edit, collide and draw, and log what the other one sees.

require 'json'

module TeamHub
  module SelfTest
    class << self
      def active?
        path = ENV['TEAMHUB_SELFTEST']
        path && File.exist?(path)
      end

      def start
        @cfg = JSON.parse(File.read(ENV['TEAMHUB_SELFTEST'], encoding: 'bom|utf-8'))
        @role = @cfg['role']
        @stage = 0
        @at = Time.now
        log("start (SketchUp #{Sketchup.version}, plugin #{PLUGIN_VERSION})")
        @timer = UI.start_timer(0.05, true) { tick } # 50 ms: latencies measured to ±50 ms
      end

      def log(msg)
        File.open(@cfg['log'], 'a:UTF-8') { |f| f.puts("#{Time.now.strftime('%H:%M:%S.%L')} [#{@role}] #{msg}") }
      end

      def bus
        File.exist?(@cfg['bus']) ? JSON.parse(File.read(@cfg['bus'])) : {}
      rescue StandardError
        {}
      end

      def post(key)
        b = bus
        b[key] = Time.now.to_f
        File.write(@cfg['bus'], JSON.generate(b))
      end

      def seen(key)
        bus[key]
      end

      def nxt(msg = nil)
        log(msg) if msg
        @stage += 1
        @at = Time.now
      end

      def since
        Time.now - @at
      end

      def model
        Sketchup.active_model
      end

      def group(name)
        model.entities.find { |e| e.is_a?(Sketchup::Group) && e.name == name }
      end

      def origin(g)
        o = g.transformation.origin
        [o.x.to_f.round(1), o.y.to_f.round(1), o.z.to_f.round(1)]
      end

      def box(name, x)
        g = model.entities.add_group
        f = g.entities.add_face([x, 0, 0], [x + 50, 0, 0], [x + 50, 50, 0], [x, 50, 0])
        f.reverse! if f.normal.z < 0
        f.pushpull(50)
        g.name = name
        g
      end

      def edit(name)
        model.start_operation(name, true)
        yield
        model.commit_operation
      end

      def check(ok, what)
        log("#{ok ? 'PASS' : 'FAIL'} #{what}")
      end

      def tick
        return if @stage.negative?
        if since > 90
          log("TIMEOUT at stage #{@stage}")
          @stage = -1
          return
        end
        @role == 'A' ? step_a : step_b
      rescue StandardError => e
        log("ERROR stage #{@stage}: #{e.class}: #{e.message} #{e.backtrace.first}")
        @stage = -1
      end

      def connected?
        s = TeamHub.session
        s && s.instance_variable_get(:@loaded) && s.status == :online && s.model == model
      end

      # ------------------------------------------------------------ helpers for the v1.7 scenarios
      # faces at local y, and at the right local x (500..520) — checked while
      # no edit context is open, so positions are the container's own
      def faces_at_y(ents, y)
        ents.grep(Sketchup::Face).count do |f|
          f.vertices.all? { |v| (v.position.y.to_f - y).abs < 0.01 && v.position.x.to_f.between?(499.99, 520.01) }
        end
      end

      # while an edit context is open positions are reported in model space
      def faces_y(ents, y)
        open = !(model.active_path || []).empty?
        wy = open ? Geom::Point3d.new(510, y, 0).transform(model.edit_transform).y.to_f : y
        ents.grep(Sketchup::Face).count { |f| f.vertices.all? { |v| (v.position.y.to_f - wy).abs < 0.01 } }
      end

      def groups_summary
        model.entities.to_a.select { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
             .map { |g| "#{g.name.empty? ? g.definition.name : g.name}@#{origin(g).inspect}" }.sort.join(' | ')
      end

      def cdef
        model.definitions.find { |d| d.name.start_with?('Cbox') && !d.instances.empty? }
      end

      def inst(name)
        model.entities.find { |e| e.is_a?(Sketchup::ComponentInstance) && e.name == name }
      end

      # local points; while the container is open SketchUp wants model coordinates
      def add_face_in(container, y)
        open = (model.active_path || []).last == container
        tr = open ? model.edit_transform : container.transformation
        pts = [[500, y, 0], [520, y, 0], [520, y, 20], [500, y, 20]].map { |p| Geom::Point3d.new(*p).transform(tr) }
        ents = container.is_a?(Sketchup::Group) ? container.entities : container.definition.entities
        edit("face y=#{y}") { ents.add_face(pts) }
      end

      def ms_since(key)
        ((Time.now.to_f - seen(key)) * 1000).round
      end

      def transport
        TeamHub.session.snapshot[:transport]
      end

      # ------------------------------------------------------------ bot A (shares the file)
      def step_a
        case @stage
        when 0
          TeamHub.login(@cfg['server'], @cfg['user'], @cfg['pass'])
          nxt('login sent')
        when 1
          return unless TeamHub.logged_in? && TeamHub.me
          edit('test content') do
            model.entities.clear!
            box('G1', 0)
            box('G2', 500)
            d = model.definitions.add('Cbox')
            f = d.entities.add_face([500, 0, 0], [550, 0, 0], [550, 50, 0], [500, 50, 0])
            f.reverse! if f.normal.z < 0
            f.pushpull(50)
            model.entities.add_instance(d, Geom::Transformation.new([2000, 0, 0])).name = 'C1'
            model.entities.add_instance(d, Geom::Transformation.new([3000, 500, 0])).name = 'C2'
          end
          model.save(@cfg['file'])
          TeamHub.load_projects { TeamHub.share_file }
          nxt('model built (G1, G2, component Cbox ×2) + share requested')
        when 2
          return unless connected? && transport == 'websocket'
          post('A:shared')
          nxt("shared + live over #{transport}")
        when 3
          return unless seen('B:joined')
          edit('move G1') { group('G1').transform!(Geom::Transformation.new([100, 0, 0])) }
          post('A:moved_g1')
          nxt('moved G1 +100 x')
        when 4
          return unless seen('B:saw_move')
          edit('move G2') { group('G2').transform!(Geom::Transformation.new([1000, 0, 0])) }
          post('A:moved_g2')
          nxt('moved G2 +1000 x (its own coordinates now differ from the model)')
        when 5
          return unless seen('B:ready')
          model.active_path = [group('G2')]
          post('A:in_g2')
          nxt('opened G2')
        when 6
          return unless seen('B:in_g2')
          add_face_in(group('G2'), 60)
          post('A:drew')
          nxt('drew inside G2 (y=60) while B draws inside it too')
        when 7
          return unless seen('B:drew')
          if faces_y(group('G2').entities, 80) == 1
            check(true, "B's face inside G2 appeared on A #{ms_since('B:drew')} ms after B drew it (both inside G2)")
            nxt
          elsif since > 6
            check(false, "B's face inside G2 never appeared on A")
            nxt
          end
        when 8
          return if since < 2
          model.active_path = nil
          g2 = group('G2')
          check(faces_at_y(g2.entities, 60) == 1 && faces_at_y(g2.entities, 80) == 1,
                "both drawings in the same G2 on A (y=60: #{faces_at_y(g2.entities, 60)}, y=80: #{faces_at_y(g2.entities, 80)})")
          post('A:checked')
          nxt
        when 9
          return unless seen('B:checked')
          model.active_path = [inst('C1')]
          post('A:in_c1')
          nxt('opened component instance C1')
        when 10
          return unless seen('B:in_c2')
          add_face_in(inst('C1'), 60)
          post('A:drew_c')
          nxt('drew inside the component through C1 (y=60) while B draws through C2')
        when 11
          return unless seen('B:drew_c')
          if faces_y(cdef.entities, 80) == 1
            check(true, "B's face in the component appeared on A #{ms_since('B:drew_c')} ms after B drew it")
            nxt
          elsif since > 6
            check(false, "B's face in the component never appeared on A")
            nxt
          end
        when 12
          return if since < 2
          model.active_path = nil
          d = cdef
          check(faces_at_y(d.entities, 60) == 1 && faces_at_y(d.entities, 80) == 1,
                "both drawings in the same component on A (y=60: #{faces_at_y(d.entities, 60)}, y=80: #{faces_at_y(d.entities, 80)})")
          check(d.instances.size == 2 && model.definitions.count { |x| x.name.start_with?('Cbox') } == 1,
                "component still one definition with its 2 instances on A (defs: #{model.definitions.map(&:name).grep(/Cbox/).inspect})")
          post('A:c_checked')
          nxt
        when 13
          return unless seen('B:c_checked')
          model.active_path = [group('G2')]
          post('A:in_g2_again')
          nxt('opened G2 again (B draws a loose line now)')
        when 14
          return unless seen('B:drew_line')
          e = model.entities.grep(Sketchup::Edge).find { |x| (x.start.position.y.to_f + 200).abs < 0.01 }
          if e
            check(true, "B's loose line appeared on A #{ms_since('B:drew_line')} ms after B drew it (A inside G2)")
            nxt
          elsif since > 6
            check(false, "B's loose line never appeared on A")
            nxt
          end
        when 15
          return if since < 1
          model.active_path = nil
          e = model.entities.grep(Sketchup::Edge).find { |x| (x.start.position.y.to_f + 200).abs < 0.01 }
          pts = e ? [e.start.position, e.end.position].map { |p| [p.x.to_f.round(2), p.y.to_f.round(2), p.z.to_f.round(2)] }.sort : nil
          check(pts == [[0.0, -200.0, 0.0], [300.0, -200.0, 0.0]], "loose line at the same coordinates on A (#{pts.inspect})")
          nxt
        when 16
          post('A:conflict_go')
          edit('A moves G1') { group('G1').transform!(Geom::Transformation.new([0, 0, 50])) }
          nxt('moved G1 +50 z at the same moment as B')
        when 17
          return if since < 8
          check(model.entities.grep(Sketchup::Group).size == 2, "no copies after both moved G1 (#{groups_summary})")
          check(origin(inst('C1')) == [2000.0, 0.0, 0.0] && origin(inst('C2')) == [3000.0, 500.0, 0.0],
                "component copies did not teleport on A (C1 #{origin(inst('C1')).inspect}, C2 #{origin(inst('C2')).inspect})")
          post("A:final=#{groups_summary}")
          nxt
        when 18
          b = bus.keys.find { |k| k.start_with?('B:final=') }
          return unless b || since > 10
          check(b && b.sub('B:final=', '') == groups_summary, "A and B ended identical: #{groups_summary}")
          log("transport=#{transport} ping A→server: #{TeamHub.session.ping_ms.inspect} ms")
          log('DONE')
          @stage = -1
        end
      end

      # ------------------------------------------------------------ bot B (downloads and joins)
      def step_b
        case @stage
        when 0
          TeamHub.login(@cfg['server'], @cfg['user'], @cfg['pass'])
          nxt('login sent')
        when 1
          return unless TeamHub.logged_in? && seen('A:shared')
          TeamHub.load_projects do
            p = (TeamHub.instance_variable_get(:@projects) || []).reverse.find { |x| x['file'] }
            TeamHub.download_shared(p['id']) if p
          end
          nxt('download of shared file requested')
        when 2
          return unless connected? && group('G1') && group('G2') && transport == 'websocket'
          post('B:joined')
          nxt("joined: shared file opened (#{model.entities.length} objects), live over #{transport}")
        when 3
          return unless seen('A:moved_g1') && origin(group('G1')) == [100.0, 0.0, 0.0]
          check(true, "A's move of G1 arrived on B #{ms_since('A:moved_g1')} ms after A moved it")
          post('B:saw_move')
          nxt
        when 4
          return unless seen('A:moved_g2') && origin(group('G2')) == [1000.0, 0.0, 0.0]
          check(true, "A's move of G2 arrived on B #{ms_since('A:moved_g2')} ms after A moved it")
          post('B:ready')
          nxt
        when 5
          return unless seen('A:in_g2')
          model.active_path = [group('G2')]
          post('B:in_g2')
          add_face_in(group('G2'), 80)
          post('B:drew')
          nxt('opened G2 and drew (y=80) at the same time as A')
        when 6
          return unless seen('A:drew')
          if faces_y(group('G2').entities, 60) == 1
            check(true, "A's face inside G2 appeared on B #{ms_since('A:drew')} ms after A drew it (both inside G2)")
            nxt
          elsif since > 6
            check(false, "A's face inside G2 never appeared on B")
            nxt
          end
        when 7
          return if since < 2
          model.active_path = nil
          g2 = group('G2')
          check(faces_at_y(g2.entities, 60) == 1 && faces_at_y(g2.entities, 80) == 1,
                "both drawings in the same G2 on B (y=60: #{faces_at_y(g2.entities, 60)}, y=80: #{faces_at_y(g2.entities, 80)})")
          post('B:checked')
          nxt
        when 8
          return unless seen('A:in_c1')
          model.active_path = [inst('C2')]
          post('B:in_c2')
          add_face_in(inst('C2'), 80)
          post('B:drew_c')
          nxt('opened component instance C2 and drew (y=80) at the same time as A')
        when 9
          return unless seen('A:drew_c')
          if faces_y(cdef.entities, 60) == 1
            check(true, "A's face in the component appeared on B #{ms_since('A:drew_c')} ms after A drew it")
            nxt
          elsif since > 6
            check(false, "A's face in the component never appeared on B")
            nxt
          end
        when 10
          return if since < 2
          model.active_path = nil
          d = cdef
          check(faces_at_y(d.entities, 60) == 1 && faces_at_y(d.entities, 80) == 1,
                "both drawings in the same component on B (y=60: #{faces_at_y(d.entities, 60)}, y=80: #{faces_at_y(d.entities, 80)})")
          check(d.instances.size == 2 && model.definitions.count { |x| x.name.start_with?('Cbox') } == 1,
                "component still one definition with its 2 instances on B (defs: #{model.definitions.map(&:name).grep(/Cbox/).inspect})")
          post('B:c_checked')
          nxt
        when 11
          return unless seen('A:in_g2_again')
          edit('loose line') { model.entities.add_line([0, -200, 0], [300, -200, 0]) }
          post('B:drew_line')
          nxt('drew a loose line while A is inside G2')
        when 12
          return unless seen('A:conflict_go')
          edit('B moves G1') { group('G1').transform!(Geom::Transformation.new([1000, 0, 0])) }
          nxt('moved G1 +1000 x at the same moment as A')
        when 13
          return if since < 8
          check(model.entities.grep(Sketchup::Group).size == 2, "no copies after both moved G1 (#{groups_summary})")
          check(origin(inst('C1')) == [2000.0, 0.0, 0.0] && origin(inst('C2')) == [3000.0, 500.0, 0.0],
                "component copies did not teleport on B (C1 #{origin(inst('C1')).inspect}, C2 #{origin(inst('C2')).inspect})")
          post("B:final=#{groups_summary}")
          log("transport=#{transport} ping B→server: #{TeamHub.session.ping_ms.inspect} ms")
          log('DONE')
          @stage = -1
        end
      end
    end
  end

  if SelfTest.active?
    # Keep the test away from the real saved login: once main.rb has finished
    # defining pref/set_pref, replace them with an in-memory store.
    UI.start_timer(3, false) do
      TeamHub.instance_variable_set(:@test_prefs, {})
      TeamHub.define_singleton_method(:pref) { |key, default = nil| @test_prefs.key?(key) ? @test_prefs[key] : default }
      TeamHub.define_singleton_method(:set_pref) { |key, value| @test_prefs[key] = value }
      TeamHub.stop_session
      SelfTest.start
    end
  end
end
