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

      # ------------------------------------------------------------ helpers (v2 reliability scenarios)
      def objs
        model.entities.to_a.select { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
      end

      # internal names like "Group#12" differ between computers: don't compare them
      def label(e)
        return e.name unless e.name.empty?
        e.is_a?(Sketchup::Group) ? 'group' : e.definition.name
      end

      def sh(ents)
        TeamHub.session.sighash_of_entities(ents)[0, 10]
      end

      def loose_ents
        model.entities.to_a.select { |e| e.is_a?(Sketchup::Face) || e.is_a?(Sketchup::Edge) }
      end

      # readable list of the loose geometry, to see what differs
      def loose_dump
        loose_ents.map do |e|
          if e.is_a?(Sketchup::Edge)
            "E#{[e.start.position, e.end.position].map { |p| [p.x, p.y, p.z].map { |v| v.to_f.round(2) } }.sort.inspect}#{e.soft? ? 's' : ''}"
          else
            "F#{e.outer_loop.vertices.map { |v| [v.position.x, v.position.y].map { |c| c.to_f.round(2) } }.sort.inspect}/#{e.loops.size}/#{e.material&.name}/#{e.back_material&.name}/n#{e.normal.to_a.map { |c| c.round(2) }.inspect}"
          end
        end.sort.join(' ')
      end

      # The whole model: every object (name, position, contents) + loose geometry.
      def fingerprint
        parts = objs.map { |e| "#{label(e)}@#{origin(e).inspect}##{sh(e.definition.entities)}" }
        parts << "loose##{sh(loose_ents)}(#{loose_ents.size})"
        parts.sort.join(' | ')
      end

      def inst(name)
        model.entities.find { |e| e.is_a?(Sketchup::ComponentInstance) && e.name == name }
      end

      def groups_named(name)
        model.entities.grep(Sketchup::Group).select { |g| g.name == name }
      end

      def draw_in(container, y, split: false)
        open = (model.active_path || []).last == container
        tr = open ? model.edit_transform : container.transformation
        ents = container.is_a?(Sketchup::Group) ? container.entities : container.definition.entities
        w = ->(x, yy, z) { Geom::Point3d.new(x, yy, z).transform(tr) }
        edit("draw y=#{y}") do
          ents.add_face(w.(500, y, 0), w.(540, y, 0), w.(540, y, 30), w.(500, y, 30))
          ents.add_line(w.(520, y, 0), w.(520, y, 30)) if split # splits the face in two
        end
      end

      def ms_since(key)
        ((Time.now.to_f - seen(key)) * 1000).round
      end

      def transport
        TeamHub.session.snapshot[:transport]
      end

      # is there a line at model y (loose, or inside any object, in true model coordinates)?
      def edge_at_y?(y)
        hit = ->(e, tr) { e.is_a?(Sketchup::Edge) && [e.start, e.end].all? { |v| (v.position.transform(tr).y.to_f - y).abs < 0.01 } }
        loose_ents.any? { |e| hit.(e, IDENTITY) } ||
          objs.any? { |o| o.definition.entities.any? { |e| hit.(e, o.transformation) } }
      end

      IDENTITY = Geom::Transformation.new

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
            model.entities.add_face([0, -600, 0], [200, -600, 0], [200, -400, 0], [0, -400, 0])
          end
          model.save(@cfg['file'])
          TeamHub.load_projects { TeamHub.share_file }
          nxt('model: G1, G2, component Cbox ×2, a loose face + share requested')
        when 2
          return unless connected? && transport == 'websocket'
          post('A:shared')
          nxt("shared, live over #{transport}")
        when 3
          return unless seen('B:joined')
          edit('split loose face') { model.entities.add_line([100, -600, 0], [100, -400, 0]) }
          post("A:loose=#{sh(loose_ents)}")
          log("A loose: #{loose_dump}")
          post('A:split')
          nxt("split the loose face (#{loose_ents.grep(Sketchup::Face).size} faces now)")
        when 4
          return unless seen('B:split_ok')
          model.selection.clear
          model.active_path = [group('G1')]
          post('A:in_g1')
          nxt('opened G1 (B must be blocked from it)')
        when 5
          return unless seen('B:blocked_done') && seen('B:in_g2')
          draw_in(group('G1'), 70, split: true)
          post('A:drew_g1')
          nxt('drew + split a face inside G1 while B draws inside G2')
        when 6
          return unless seen('B:drew_g2') && since > 1
          model.active_path = nil
          model.selection.clear
          post('A:left_g1')
          nxt('left G1')
        when 7
          return unless seen('B:left_g2') && since > 12 # claims released + uploads done
          model.active_path = [inst('C1')]
          draw_in(inst('C1'), 70)
          model.active_path = nil
          model.selection.clear
          post('A:drew_c')
          nxt('drew inside the component (through C1)')
        when 8
          return unless seen('B:comp_ok') || since > 25
          post('A:move_go')
          edit('A moves G1') { group('G1').transform!(Geom::Transformation.new([0, 0, 50])) }
          model.selection.clear
          nxt('moved G1 +50 z while B moves G2')
        when 9
          return if since < 12
          copy = nil
          edit('copy G2') do
            copy = group('G2').copy
            copy.name = 'G2 copy'
            copy.transform!(Geom::Transformation.new([0, 300, 0]))
          end
          model.selection.clear
          post('A:copied')
          nxt('copied G2 → "G2 copy"')
        when 10
          return unless seen('B:deleted')
          gone = groups_named('G2 copy').empty? && groups_named('G2').size == 1
          return unless gone || ms_since('B:deleted') > 8000
          check(gone, "B's delete of the copy arrived on A #{ms_since('B:deleted')} ms later (copies #{groups_named('G2 copy').size}, G2 #{groups_named('G2').size})")
          post('A:loose_go')
          edit('A loose line') { model.entities.add_line([0, -700, 0], [300, -700, 0]) }
          nxt('drew a loose line at the same moment as B')
        when 11
          return if since < 15
          check(edge_at_y?(-700) && edge_at_y?(-800), "both simultaneous loose lines exist on A (mine -700: #{edge_at_y?(-700)}, B's -800: #{edge_at_y?(-800)})")
          post("A:fp=#{fingerprint}")
          nxt
        when 12
          b = bus.keys.find { |k| k.start_with?('B:fp=') }
          return unless b || since > 15
          mine = fingerprint
          theirs = b && b.sub('B:fp=', '')
          check(theirs == mine, 'WHOLE MODEL identical on A and B (objects, positions, contents, loose)')
          log("A model: #{mine}")
          log("B model: #{theirs}") if theirs != mine
          log("transport=#{transport} ping=#{TeamHub.session.ping_ms.inspect} ms")
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
          nxt("joined (#{objs.size} objects, #{loose_ents.size} loose), live over #{transport}")
        when 3
          k = bus.keys.find { |x| x.start_with?('A:loose=') }
          return unless k && seen('A:split')
          if sh(loose_ents) == k.sub('A:loose=', '')
            check(true, "A's split of the loose face arrived on B identical (#{ms_since('A:split')} ms, #{loose_ents.grep(Sketchup::Face).size} faces)")
            post('B:split_ok')
            nxt
          elsif since > 8
            check(false, "loose face after A's split differs on B (#{loose_ents.grep(Sketchup::Face).size} faces)")
            log("B loose: #{loose_dump}")
            post('B:split_ok')
            nxt
          end
        when 4
          return unless seen('A:in_g1')
          g1 = group('G1')
          if g1.locked?
            check(true, "G1 locked on B #{ms_since('A:in_g1')} ms after A opened it")
            @g1_before = sh(g1.definition.entities)
            begin
              model.active_path = [g1]
              nxt('tried to open G1 anyway (SketchUp allowed it)')
            rescue ArgumentError => e
              nxt("tried to open G1 anyway: SketchUp refused (#{e.message})")
            end
          elsif since > 4
            check(false, 'G1 never got locked on B while A is editing it')
            nxt
          end
        when 5
          return if since < 1.5
          check((model.active_path || []).empty? || (model.active_path || []).first != group('G1'), "B was kept out of G1 (path #{(model.active_path || []).map { |e| label(e) }.inspect})")
          model.active_path = nil
          post('B:blocked_done')
          model.active_path = [group('G2')]
          post('B:in_g2')
          draw_in(group('G2'), 80, split: true)
          post('B:drew_g2')
          nxt('opened G2 and drew + split a face inside it at the same time as A in G1')
        when 6
          return unless seen('A:drew_g1') && since > 2
          model.active_path = nil
          model.selection.clear
          post('B:left_g2')
          nxt('left G2')
        when 7
          return unless seen('A:drew_c')
          d = inst('C1').definition
          arrived = d.instances.size == 2 && d.entities.grep(Sketchup::Face).size >= 7
          return unless arrived || ms_since('A:drew_c') > 8000
          check(arrived, "A's drawing in the component reached B #{ms_since('A:drew_c')} ms after A drew it (faces #{d.entities.grep(Sketchup::Face).size}, copies #{d.instances.size})")
          check(origin(inst('C1')) == [2000.0, 0.0, 0.0] && origin(inst('C2')) == [3000.0, 500.0, 0.0], "component copies stayed in place on B (C1 #{origin(inst('C1')).inspect}, C2 #{origin(inst('C2')).inspect})")
          post('B:comp_ok')
          nxt
        when 8
          return unless seen('A:move_go')
          edit('B moves G2') { group('G2').transform!(Geom::Transformation.new([0, 70, 0])) }
          model.selection.clear
          nxt('moved G2 +70 y while A moves G1')
        when 9
          return unless seen('A:copied')
          if groups_named('G2 copy').size == 1 && groups_named('G2').size == 1
            check(true, "A's copy of G2 arrived on B exactly once (#{ms_since('A:copied')} ms)")
            nxt
          elsif ms_since('A:copied') > 8000
            check(false, "A's copy: #{groups_named('G2 copy').size} copies and #{groups_named('G2').size} G2 on B (expected 1 and 1)")
            nxt
          end
        when 10
          return if since < 10 # the copy's claim on A's side expires first
          copy = groups_named('G2 copy').first
          edit('B deletes the copy') { copy&.erase! }
          post('B:deleted')
          nxt('deleted the copy')
        when 11
          return unless seen('A:loose_go')
          edit('B loose line') { model.entities.add_line([0, -800, 0], [300, -800, 0]) }
          nxt('drew a loose line at the same moment as A')
        when 12
          return if since < 16.5
          check(edge_at_y?(-700) && edge_at_y?(-800), "both simultaneous loose lines exist on B (A's -700: #{edge_at_y?(-700)}, mine -800: #{edge_at_y?(-800)})")
          post("B:fp=#{fingerprint}")
          log("B model: #{fingerprint}")
          log("transport=#{transport} ping=#{TeamHub.session.ping_ms.inspect} ms")
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
