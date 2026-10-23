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
        @timer = UI.start_timer(0.5, true) { tick }
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
      def faces_at_y(g, y)
        g.definition.entities.grep(Sketchup::Face).count do |f|
          f.vertices.all? { |v| (v.position.y.to_f - y).abs < 0.01 }
        end
      end

      def groups_summary
        model.entities.grep(Sketchup::Group).map { |g| "#{g.name}@#{origin(g).inspect}" }.sort.join(' | ')
      end

      def add_wall_face(g, y)
        # local points; while the group is open SketchUp wants model coordinates
        tr = g.transformation
        pts = [[500, y, 0], [520, y, 0], [520, y, 20], [500, y, 20]].map { |p| Geom::Point3d.new(*p).transform(tr) }
        edit("face y=#{y}") { g.entities.add_face(pts) }
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
          end
          model.save(@cfg['file'])
          TeamHub.load_projects { TeamHub.share_file }
          nxt('model built + share requested')
        when 2
          return unless connected?
          post('A:shared')
          nxt('shared + live')
        when 3
          return unless seen('B:joined')
          edit('move G1') { group('G1').transform!(Geom::Transformation.new([100, 0, 0])) }
          post('A:moved_g1')
          nxt('moved G1 +100 x')
        when 4
          return unless seen('B:saw_move')
          edit('move G2') { group('G2').transform!(Geom::Transformation.new([1000, 0, 0])) }
          post('A:moved_g2')
          nxt('moved G2 +1000 x (so its own coordinates differ from the model)')
        when 5
          return unless seen('B:ready')
          model.active_path = [group('G2')]
          post('A:in_g2')
          nxt('opened G2')
        when 6
          return unless seen('B:in_g2')
          add_wall_face(group('G2'), 60)
          post('A:drew')
          nxt('drew a face inside G2 (y=60) while B is drawing in it too')
        when 7
          return unless seen('B:drew') && since > 4
          model.active_path = nil
          g2 = group('G2')
          check(faces_at_y(g2, 60) == 1 && faces_at_y(g2, 80) == 1,
                "both drawings inside the same G2 are on A (mine y=60: #{faces_at_y(g2, 60)}, B's y=80: #{faces_at_y(g2, 80)})")
          check(model.entities.grep(Sketchup::Group).size == 2, "no copies on A (#{groups_summary})")
          post('A:checked')
          nxt
        when 8
          return unless seen('B:checked')
          model.active_path = [group('G2')]
          post('A:in_g2_again')
          nxt('opened G2 again (B will draw a loose line now)')
        when 9
          return unless seen('B:drew_line') && since > 3
          model.active_path = nil
          e = model.entities.grep(Sketchup::Edge).find { |x| (x.start.position.y.to_f + 200).abs < 0.01 }
          pts = e ? [e.start.position, e.end.position].map { |p| [p.x.to_f.round(2), p.y.to_f.round(2), p.z.to_f.round(2)] }.sort : nil
          check(pts == [[0.0, -200.0, 0.0], [300.0, -200.0, 0.0]],
                "B's loose line landed at the same place on A, though A was inside G2 (#{pts.inspect})")
          nxt
        when 10
          post('A:conflict_go')
          edit('A moves G1') { group('G1').transform!(Geom::Transformation.new([0, 0, 50])) }
          nxt('moved G1 +50 z at the same moment as B')
        when 11
          return if since < 12
          check(model.entities.grep(Sketchup::Group).size == 2, "no copies after both moved G1 (#{groups_summary})")
          post("A:final=#{groups_summary}")
          nxt
        when 12
          b = bus.keys.find { |k| k.start_with?('B:final=') }
          return unless b || since > 10
          check(b && b.sub('B:final=', '') == groups_summary, "A and B ended identical: #{groups_summary}")
          log("ping A→server: #{TeamHub.session.ping_ms.inspect} ms")
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
          return unless connected? && group('G1') && group('G2')
          post('B:joined')
          nxt("joined: shared file opened (#{model.entities.length} objects), live")
        when 3
          return unless (t = seen('A:moved_g1'))
          return unless origin(group('G1')) == [100.0, 0.0, 0.0]
          check(true, "A's move of G1 arrived on B #{((Time.now.to_f - t) * 1000).round} ms later")
          post('B:saw_move')
          nxt
        when 4
          return unless (t = seen('A:moved_g2'))
          return unless origin(group('G2')) == [1000.0, 0.0, 0.0]
          check(true, "A's move of G2 arrived on B #{((Time.now.to_f - t) * 1000).round} ms later")
          post('B:ready')
          nxt
        when 5
          return unless seen('A:in_g2')
          model.active_path = [group('G2')]
          post('B:in_g2')
          add_wall_face(group('G2'), 80)
          post('B:drew')
          nxt('opened G2 and drew a face (y=80) at the same time as A')
        when 6
          return unless seen('A:drew') && since > 4
          model.active_path = nil
          g2 = group('G2')
          check(faces_at_y(g2, 60) == 1 && faces_at_y(g2, 80) == 1,
                "both drawings inside the same G2 are on B (A's y=60: #{faces_at_y(g2, 60)}, mine y=80: #{faces_at_y(g2, 80)})")
          check(model.entities.grep(Sketchup::Group).size == 2, "no copies on B (#{groups_summary})")
          post('B:checked')
          nxt
        when 7
          return unless seen('A:in_g2_again')
          edit('loose line') { model.entities.add_line([0, -200, 0], [300, -200, 0]) }
          post('B:drew_line')
          nxt('drew a loose line while A is inside G2')
        when 8
          return unless seen('A:conflict_go')
          edit('B moves G1') { group('G1').transform!(Geom::Transformation.new([1000, 0, 0])) }
          nxt('moved G1 +1000 x at the same moment as A')
        when 9
          return if since < 12
          check(model.entities.grep(Sketchup::Group).size == 2, "no copies after both moved G1 (#{groups_summary})")
          post("B:final=#{groups_summary}")
          log("ping B→server: #{TeamHub.session.ping_ms.inspect} ms")
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
