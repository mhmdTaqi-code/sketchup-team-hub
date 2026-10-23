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
          nxt('moved G1 by +100 x')
        when 4
          return unless seen('B:editing_g2')
          @wait_lock = Time.now
          nxt
        when 5
          g2 = group('G2')
          if g2&.locked?
            check(true, "G2 locked on A #{((Time.now.to_f - seen('B:editing_g2')) * 1000).round} ms after B opened it (B is editing it)")
            edit('move G1 again') { group('G1').transform!(Geom::Transformation.new([0, 100, 0])) }
            post('A:moved_g1_again')
            nxt('moved G1 by +100 y while B is inside G2')
          elsif since > 6
            check(false, 'G2 never got locked on A while B edited it')
            post('A:moved_g1_again')
            nxt
          end
        when 6
          return unless seen('B:done_g2')
          g2 = group('G2')
          faces = g2 ? g2.entities.grep(Sketchup::Face).size : 0
          return if since < 25 && (g2.nil? || faces < 7 || g2.locked?)
          check(g2 && faces >= 7, "B's edit inside G2 arrived (faces=#{faces})")
          check(g2 && !g2.locked?, 'G2 unlocked on A after B finished')
          check(g2 && origin(g2) == [0.0, 0.0, 0.0], "G2 did not teleport on A (origin #{g2 && origin(g2).inspect})")
          check(origin(group('G1')) == [100.0, 100.0, 0.0], "G1 where A put it (#{origin(group('G1')).inspect})")
          nxt
        when 7
          post('A:conflict_go')
          edit('A moves G1 in conflict') { group('G1').transform!(Geom::Transformation.new([0, 0, 50])) }
          nxt('conflict: moved G1 +50 z at the same time as B')
        when 8
          return if since < 12
          groups = model.entities.grep(Sketchup::Group).map { |g| "#{g.name}@#{origin(g).inspect}" }
          log("after conflict, groups on A: #{groups.join(' | ')}")
          nxt
        when 9
          return unless seen('B:drew_line')
          edges = model.entities.grep(Sketchup::Edge).size
          return if edges.zero? && since < 15
          check(edges.positive?, "B's loose line arrived on A #{((Time.now.to_f - seen('B:drew_line')) * 1000).round} ms after B drew it (edges=#{edges})")
          nxt
        when 10
          edit('move G2 #1') { group('G2').transform!(Geom::Transformation.new([10, 0, 0])) }
          nxt
        when 11
          return if since < 3
          edit('move G2 #2') { group('G2').transform!(Geom::Transformation.new([10, 0, 0])) }
          post('A:moved_g2')
          nxt('moved G2 twice (second move = position only)')
        when 12
          return if since < 4
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
          check(true, "A's move of G1 arrived on B #{((Time.now.to_f - t) * 1000).round} ms after A moved it")
          post('B:saw_move')
          nxt
        when 4
          g2 = group('G2')
          model.active_path = [g2]
          edit('B edits inside G2') { g2.entities.add_face([520, 10, 50], [540, 10, 50], [540, 10, 80], [520, 10, 80]) }
          post('B:editing_g2')
          nxt('opened G2 and added a face inside it')
        when 5
          return unless seen('A:moved_g1_again') && since > 3
          model.active_path = nil
          post('B:done_g2')
          nxt('closed G2')
        when 6
          return if since < 4
          check(origin(group('G1')) == [100.0, 100.0, 0.0], "G1 on B where A put it, received while B was inside G2 (#{origin(group('G1')).inspect})")
          check(origin(group('G2')) == [0.0, 0.0, 0.0], "G2 did not teleport on B (#{origin(group('G2')).inspect})")
          nxt
        when 7
          return unless seen('A:conflict_go')
          g1 = group('G1')
          g1.locked = false
          edit('B moves G1 in conflict') { g1.transform!(Geom::Transformation.new([1000, 0, 0])) }
          nxt('conflict: moved G1 +1000 x at the same time as A')
        when 8
          return if since < 12
          groups = model.entities.grep(Sketchup::Group).map { |g| "#{g.name}@#{origin(g).inspect}" }
          log("after conflict, groups on B: #{groups.join(' | ')}")
          nxt
        when 9
          edit('B draws a loose line') { model.entities.add_line([0, -200, 0], [300, -200, 0]) }
          post('B:drew_line')
          nxt('drew a loose line')
        when 10
          return unless (t = seen('A:moved_g2'))
          return unless origin(group('G2')) == [20.0, 0.0, 0.0]
          check(true, "A's second move of G2 (position only) arrived on B #{((Time.now.to_f - t) * 1000).round} ms after A moved it")
          nxt
        when 11
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
