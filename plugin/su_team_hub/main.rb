# Team Hub: entry point — settings, login, panel actions, menus, toolbar,
# and model switching. The sync engine itself is in session.rb.

require 'json'
require 'su_team_hub/client'
require 'su_team_hub/session'
require 'su_team_hub/loose'
require 'su_team_hub/realtime'
require 'su_team_hub/delta'
require 'su_team_hub/ws'
require 'su_team_hub/live_ws'
require 'su_team_hub/reliable'
require 'su_team_hub/selftest'
require 'su_team_hub/overlay'
require 'su_team_hub/panel'
require 'su_team_hub/shared'

module TeamHub
  PREFS = 'TeamHub'.freeze
  DIR = File.dirname(__FILE__)

  class << self
    attr_reader :session

    # ------------------------------------------------------------ helpers

    def log_error(e)
      puts "[Team Hub] #{e.class}: #{e.message}\n  #{Array(e.backtrace).first(6).join("\n  ")}"
      log_sync("ERROR #{e.class}: #{e.message} @ #{Array(e.backtrace).first(3).join(' < ')}") if respond_to?(:log_sync)
    end

    def pref(key, default = nil)
      Sketchup.read_default(PREFS, key, default)
    end

    def set_pref(key, value)
      Sketchup.write_default(PREFS, key, value)
    end

    # Stored base64-encoded: Sketchup.write_default mangles strings with quotes.
    def me
      raw = pref('me').to_s
      raw.empty? ? nil : JSON.parse(raw.unpack1('m0').force_encoding('UTF-8'))
    rescue StandardError
      nil
    end

    def set_me(user)
      set_pref('me', user ? [JSON.generate(user)].pack('m0') : '')
    end

    def logged_in?
      !pref('token').to_s.empty? && !pref('server').to_s.empty?
    end

    def client
      Client.new(pref('server', ''), pref('token'))
    end

    def flash(text)
      Sketchup.status_text = "Team Hub: #{text}"
      panel.toast(text)
      unless panel.visible?
        ext = Sketchup.extensions['Team Hub']
        UI::Notification.new(ext, text).show if ext && defined?(UI::Notification)
      end
    rescue StandardError => e
      log_error(e)
    end

    def chat_received(event)
      who = event.dig('user', 'display_name')
      flash("💬 #{who}: #{event.dig('payload', 'text')}")
    end

    def panel
      @panel ||= Panel.new
    end

    def panel_refresh
      panel.refresh
    end

    def model_binding(model = Sketchup.active_model)
      return nil unless model
      pid = model.get_attribute(DICT, 'project_id')
      return nil unless pid
      { 'project_id' => pid, 'project_name' => model.get_attribute(DICT, 'project_name'),
        'server' => model.get_attribute(DICT, 'server') }
    end

    # Empty, or a fresh untouched file (templates often include a scale figure).
    def model_empty?(model = Sketchup.active_model)
      model.entities.length.zero? || (model.path.to_s.empty? && !model.modified?)
    end

    # What the panel shows.
    def ui_state
      model = Sketchup.active_model
      base = {
        version: PLUGIN_VERSION,
        logged_in: logged_in?,
        server: pref('server', ''),
        username: pref('username', ''),
        me: me,
        projects: @projects || [],
        binding: model_binding(model),
        model_empty: model ? model_empty?(model) : true,
        model_title: model ? model.title : '',
        busy: @busy,
        busy_text: @busy_text,
        model_saved: model ? !model.path.to_s.empty? : false,
        update: @update,
        su_version: su_version_label,
      }
      if @session && !@session.stopped? && @session.model == model
        base.merge(@session.snapshot)
      else
        base.merge(connected: false)
      end
    end

    # ------------------------------------------------------------ auth

    def login(server, username, password)
      c = Client.new(server)
      @busy = 'login'
      panel_refresh
      c.request(:post, '/api/login', { 'username' => username, 'password' => password, 'client' => 'sketchup' }, timeout: 15) do |st, data|
        @busy = nil
        if st == 200 && data
          set_pref('server', c.server)
          set_pref('username', username)
          set_pref('token', data['token'])
          set_me(data['user'])
          flash("أهلاً #{data['user']['display_name']}")
          load_projects
        elsif st.zero?
          flash("ما كدرت أوصل للسيرفر #{c.server}. تأكد من Radmin VPN والعنوان.")
        else
          flash('اسم المستخدم أو كلمة السر غلط')
        end
        panel_refresh
      end
    end

    def logout
      stop_session
      c = client
      c.request(:post, '/api/logout') if logged_in?
      set_pref('token', '')
      set_me(nil)
      @projects = []
      panel_refresh
    end

    def auth_expired
      stop_session
      set_pref('token', '')
      flash('انتهت الجلسة، سجل دخول مرة ثانية')
      panel_refresh
    end

    # ------------------------------------------------------------ updates

    def version_newer?(a, b)
      (a.to_s.split('.').map(&:to_i) <=> b.to_s.split('.').map(&:to_i)) == 1
    end

    # The server hosts the team's plugin build; offer it when it's newer.
    def check_update
      return if pref('server', '').to_s.empty?
      client.request(:get, '/api/info', nil, timeout: 15) do |st, data|
        info = st == 200 && data && data['plugin']
        @update = info && version_newer?(info['version'], PLUGIN_VERSION) ? info : nil
        panel_refresh
      end
    end

    def install_update
      return flash('ماكو تحديث') unless @update
      @busy = 'update'
      panel_refresh
      client.request(:get, '/api/plugin', nil, timeout: 120) do |st, data|
        @busy = nil
        if st == 200 && data && data['data']
          path = File.join(Sketchup.temp_dir, "su_team_hub_#{data['version']}.rbz")
          File.binwrite(path, data['data'].unpack1('m0'))
          begin
            Sketchup.install_from_archive(path)
            @update = nil
            UI.messagebox("انحدث Team Hub للنسخة #{data['version']}.\nسكّر SketchUp وافتحه مرة ثانية حتى يشتغل التحديث.")
          rescue Interrupt
            flash('انلغى التحديث')
          rescue StandardError => e
            log_error(e)
            flash("فشل التحديث: #{e.message}")
          end
        else
          flash('ما كدرت أنزّل التحديث من السيرفر')
        end
        panel_refresh
      end
    end

    def load_projects(&after)
      return unless logged_in?
      check_update
      client.request(:get, '/api/projects') do |st, data|
        if st == 200 && data
          @projects = data['projects']
          after&.call
        elsif st == 401
          auth_expired
        end
        panel_refresh
      end
    end

    # ------------------------------------------------------------ sessions

    def stop_session
      @session&.stop
      @session = nil
    end

    def start_session(model, project, mode)
      stop_session
      return unless logged_in?
      @session = Session.new(model, client, me, project)
      @session.start(mode)
      panel.show
      panel_refresh
    end

    def connect(project_id, mode)
      project = (@projects || []).find { |p| p['id'] == project_id.to_i }
      return flash('المشروع مو موجود') unless project
      model = Sketchup.active_model
      binding = model_binding(model)
      case mode
      when 'resume'
        return flash('هذا الملف مربوط بمشروع ثاني') unless binding && binding['project_id'] == project['id']
        start_session(model, project, :resume)
      when 'download'
        if model_empty?(model) && binding.nil?
          start_session(model, project, :download)
        else
          msg = 'تحميل المشروع يحتاج ملف فارغ. أفتح ملف جديد (راح يسألك إذا تريد تحفظ هذا الملف)؟'
          return unless UI.messagebox(msg, MB_YESNO) == IDYES
          stop_session
          Sketchup.file_new
          UI.start_timer(0.5, false) do
            m = Sketchup.active_model
            if model_empty?(m) && model_binding(m).nil?
              start_session(m, project, :download)
            else
              flash('ما انفتح ملف فارغ')
            end
          end
        end
      when 'upload'
        return flash('المشروع بيه محتوى. ارفع لمشروع فارغ، أو حمّل المشروع بملف جديد.') if project['objects'].to_i.positive?
        return flash('هذا الملف مربوط بمشروع ثاني') if binding && binding['project_id'] != project['id']
        raw = model.entities.count { |e| e.is_a?(Sketchup::Face) || e.is_a?(Sketchup::Edge) }
        if raw.positive?
          msg = "أكو #{raw} خط/سطح مو داخل Group. هذني ما يتزامنون مع الفريق.\n" \
                'تريد أجمعهم بـ Group واحد قبل الرفع؟ (تكدر تقسمهم بعدين)'
          case UI.messagebox(msg, MB_YESNOCANCEL)
          when IDCANCEL then return
          when IDYES then group_loose_geometry(model)
          end
        end
        start_session(model, project, :upload)
      end
    end

    def group_loose_geometry(model)
      loose = model.entities.select { |e| e.is_a?(Sketchup::Face) || e.is_a?(Sketchup::Edge) }
      return if loose.empty?
      model.start_operation('Team Hub: جمع العناصر', true)
      g = model.entities.add_group(loose)
      g.name = 'عناصر مجمّعة'
      model.commit_operation
    end

    # Reconnect automatically when a file bound to a project is opened.
    def auto_connect(model)
      binding = model_binding(model)
      # The shared file comes from the owner's PC, so the address stored in it is
      # theirs; what matters is the project on the server I'm signed in to.
      return unless binding && logged_in?
      load_projects do
        project = (@projects || []).find { |p| p['id'] == binding['project_id'] }
        if project && Sketchup.active_model == model
          start_session(model, project, :resume)
          flash("متصل بمشروع «#{project['name']}»")
        end
      end
    end

    def on_model_changed(model)
      stop_session if @session && @session.model != model
      UI.start_timer(0.5, false) { auto_connect(model) if Sketchup.active_model == model }
      panel_refresh
    end

    # ------------------------------------------------------------ panel actions

    def handle_ui(action, payload)
      s = @session
      case action
      when 'ready' then panel_refresh
      when 'login' then login(payload['server'], payload['username'], payload['password'])
      when 'logout' then logout
      when 'projects' then load_projects
      when 'create_project'
        client.request(:post, '/api/projects', { 'name' => payload['name'] }) do |st, data|
          st == 200 ? load_projects : flash("ما انشأ المشروع (#{data && data['error']})")
        end
      when 'connect' then connect(payload['project_id'], payload['mode'])
      when 'share' then share_file
      when 'download_file' then download_shared(payload['project_id'])
      when 'disconnect' then stop_session
      when 'reserve' then s&.reserve(Sketchup.active_model.selection.to_a)
      when 'release' then s&.release_entities(Sketchup.active_model.selection.to_a)
      when 'release_all' then s&.release_all
      when 'reserve_oid'
        e = s && s.live_entity(payload['oid'])
        s.reserve([e]) if e
      when 'release_oid' then s&.release([payload['oid']])
      when 'focus' then s&.focus(payload['oid'])
      when 'chat' then s&.chat(payload['text'].to_s)
      when 'resync' then s&.resync
      when 'sync_now' then s&.sync_now
      when 'dashboard' then UI.openURL(pref('server', ''))
      when 'update_plugin' then install_update
      when 'send_log' then send_log
      end
      panel_refresh
    rescue StandardError => e
      log_error(e)
      flash("خطأ: #{e.message}")
    end

    # ------------------------------------------------------------ commands

    def selection_has_trackable?
      Sketchup.active_model.selection.any? do |e|
        (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) && e.parent == Sketchup.active_model
      end
    end

    def command(title, tip, icon, &blk)
      cmd = UI::Command.new(title) { blk.call }
      cmd.tooltip = title
      cmd.status_bar_text = tip
      path = File.join(DIR, 'ui', 'icons', "#{icon}.svg")
      cmd.small_icon = cmd.large_icon = path if File.exist?(path)
      cmd
    end

    def setup_ui
      cmd_panel = command('لوحة الفريق', 'افتح لوحة Team Hub: الاتصال، الفريق، الحجوزات', 'hub') { panel.show }
      cmd_reserve = command('حجز المحدد', 'احجز العناصر المحددة حتى تعدل عليها', 'lock') do
        @session ? @session.reserve(Sketchup.active_model.selection.to_a) : panel.show
      end
      cmd_release = command('إلغاء حجز المحدد', 'ارفع آخر تعديلاتك وفك حجز العناصر المحددة', 'unlock') do
        @session ? @session.release_entities(Sketchup.active_model.selection.to_a) : panel.show
      end
      cmd_release_all = command('إلغاء كل حجوزاتي', 'فك كل العناصر اللي حاجزها', 'unlock') { @session&.release_all }
      cmd_resync = command('مزامنة كاملة', 'إعادة تحميل حالة المشروع من السيرفر', 'hub') { @session&.resync }

      [cmd_reserve, cmd_release].each do |c|
        c.set_validation_proc { @session && selection_has_trackable? ? MF_ENABLED : MF_GRAYED }
      end

      menu = UI.menu('Extensions').add_submenu('Team Hub')
      menu.add_item(cmd_panel)
      menu.add_separator
      menu.add_item(cmd_reserve)
      menu.add_item(cmd_release)
      menu.add_item(cmd_release_all)
      menu.add_separator
      menu.add_item(cmd_resync)
      menu.add_item('فتح لوحة التحكم بالمتصفح') { UI.openURL(pref('server', '')) }

      tb = UI::Toolbar.new('Team Hub')
      tb.add_item(cmd_panel)
      tb.add_item(cmd_reserve)
      tb.add_item(cmd_release)
      tb.restore

      UI.add_context_menu_handler do |ctx|
        next unless @session && selection_has_trackable?
        ctx.add_separator
        ctx.add_item('Team Hub: حجز للتعديل') { @session.reserve(Sketchup.active_model.selection.to_a) }
        ctx.add_item('Team Hub: إلغاء الحجز') { @session.release_entities(Sketchup.active_model.selection.to_a) }
      end
    end
  end

  class AppObs < Sketchup::AppObserver
    def expectsStartupModelNotifications
      true
    end

    def onNewModel(model)
      TeamHub.on_model_changed(model)
    end

    def onOpenModel(model)
      TeamHub.on_model_changed(model)
    end

    def onActivateModel(model)
      TeamHub.on_model_changed(model)
    end

    def onQuit
      TeamHub.stop_session
    end
  end

  unless file_loaded?(__FILE__)
    setup_ui
    Sketchup.add_observer(AppObs.new)
    file_loaded(__FILE__)
  end
end
