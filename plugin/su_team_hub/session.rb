# The sync engine for one model bound to one Team Hub project.
#
# Unit of sync = a top-level Group or ComponentInstance ("object").
#   group      -> blob is the group's contents (saved as a .skp definition)
#   component  -> no blob; meta.def points to a "definition" object
#   definition -> blob is the component definition, shared by all its instances
#
# Rules:
#   * You edit only what you have reserved. Everything else is locked locally.
#   * Changes to your reserved objects are pushed automatically shortly after
#     each operation. Teammates' changes are pulled by polling the event log.
#   * Model edits from the sync are made in transparent operations, and only
#     while no tool is mid-operation.

require 'json'
require 'fileutils'
require 'securerandom'

module TeamHub
  DICT = 'TeamHub'.freeze

  # Every .skp that travels between teammates is written in the SketchUp 2021
  # format. SketchUp 2021 and newer all share that format, so a member on 2024
  # and a member on 2025 can open each other's objects.
  def self.save_definition(defn, path)
    if defn.respond_to?(:save_copy) && defined?(Sketchup::Model::VERSION_2021)
      # save_copy (SU 2022+) also leaves the definition's own file path alone.
      defn.save_copy(path, Sketchup::Model::VERSION_2021)
    else
      defn.save_as(path)
    end
  end

  def self.su_version_label
    "SketchUp 20#{Sketchup.version.to_i}"
  end

  class Session
    POLL_INTERVAL = 1.5
    SCAN_DELAY = 0.8
    IDENTITY = Geom::Transformation.new

    attr_reader :model, :client, :me, :project, :status

    def initialize(model, client, me, project)
      @model = model
      @client = client
      @me = me
      @project = project
      @locks = {}          # oid => user_id
      @objects = {}        # oid => latest server object
      @users = {}          # id => user
      @online = []
      @events = []
      @seq = 0
      @index = {}          # oid => top-level entity
      @eid_to_oid = {}     # entityID => oid
      @def_index = {}      # did => ComponentDefinition
      @jobs = []           # server objects waiting to be applied, FIFO
      @job_running = false
      @pushing = {}        # oid => true while a push is in flight
      @push_wanted = {}    # oid => include content?
      @delete_wanted = {}
      @release_after = {}
      @new_local = {}      # oid => true for objects never pushed yet
      @meta_fp = {}
      @content_fp = {}
      @content_dirty = {}
      @def_dirty = {}
      @added = []
      @removed = []
      @idle_queue = []
      @suspended = 0
      @status = :connecting
      @loaded = false
      @after_undo = false
      @tool_busy = false
      @busy_since = Time.now
      @raw_count = 0
      @overlay_items = []
      @warned = {}
      @temp = File.join(Sketchup.temp_dir, 'teamhub')
      FileUtils.mkdir_p(File.join(@temp, 'blobs'))
    end

    def pid
      @project['id']
    end
    def my_id
      @me['id']
    end
    def viewer?
      @me['role'] == 'viewer'
    end
    def mine?(oid)
      !viewer? && @locks[oid] == my_id
    end
    def connected?
      @status == :online
    end
    def stopped?
      !!@stopped
    end

    # ------------------------------------------------------------ lifecycle

    # mode: :resume (model already bound), :download (empty model),
    #       :upload (push this model's content into an empty project)
    def start(mode)
      @mode = mode
      bind_model unless mode == :resume
      @model_obs = ModelObs.new(self)
      @ents_obs = EntitiesObs.new(self)
      @tools_obs = ToolsObs.new(self)
      @model.add_observer(@model_obs)
      @model.entities.add_observer(@ents_obs)
      @model.tools.add_observer(@tools_obs)
      @overlay = TeamHub.attach_overlay(@model, self)
      load_state
    end

    def stop
      @stopped = true
      UI.stop_timer(@poll_timer) if @poll_timer
      UI.stop_timer(@scan_timer) if @scan_timer
      UI.stop_timer(@idle_timer) if @idle_timer
      @poll_timer = @scan_timer = @idle_timer = nil
      [[@model, @model_obs], [@model.entities, @ents_obs], [@model.tools, @tools_obs]].each do |target, obs|
        target.remove_observer(obs) if obs
      rescue StandardError
        nil
      end
      TeamHub.detach_overlay(@model, @overlay)
      @model.active_view.invalidate rescue nil
    end

    def bind_model
      model_op('Team Hub: ربط المشروع') do
        @model.set_attribute(DICT, 'project_id', pid)
        @model.set_attribute(DICT, 'project_name', @project['name'])
        @model.set_attribute(DICT, 'server', @client.server)
      end
    end

    def load_state
      @status = :connecting
      @client.request(:get, "/api/projects/#{pid}/state", nil, timeout: 60) do |st, data|
        next if @stopped
        if st == 200 && data
          @seq = data['seq'].to_i
          @locks = {}
          data['locks'].each { |l| @locks[l['oid']] = l['user_id'] }
          data['users'].each { |u| @users[u['id']] = u }
          @online = data['online'] || []
          @objects = {}
          data['objects'].each { |o| @objects[o['oid']] = o }
          @status = :online
          @loaded = true
          start_polling
          when_idle { initial_sync }
        elsif st == 401
          TeamHub.auth_expired
        else
          @status = :offline
          UI.start_timer(5, false) { load_state unless @stopped }
        end
        notify
      end
    end

    def initial_sync
      if @mode == :download
        # A fresh file from a template (e.g. the scale figure): start clean.
        model_op('Team Hub: تجهيز الملف') do
          @model.entities.clear!
          @model.definitions.purge_unused
          @model.materials.purge_unused
        end
      end
      rebuild_index
      reconcile_with_server
      @raw_count = count_raw_geometry
      apply_local_locks
      schedule_scan(0)
    end

    # ------------------------------------------------------------ polling

    def start_polling
      UI.stop_timer(@poll_timer) if @poll_timer
      @poll_timer = UI.start_timer(POLL_INTERVAL, true) { guard { poll } }
      poll
    end

    def poll
      return if @polling || @stopped
      @polling = true
      path = "/api/projects/#{pid}/events?since=#{@seq}&limit=500&client=sketchup" \
             "&su=#{Client.q(TeamHub.su_version_label)}&pv=#{Client.q(PLUGIN_VERSION)}"
      text = status_text
      path += "&status=#{Client.q(text)}" if text
      @client.request(:get, path, nil, timeout: 20) do |st, data|
        @polling = false
        next if @stopped
        if st == 200 && data
          was_offline = !connected?
          @status = :online
          @online = data['online'] if data['online']
          data['events'].each { |e| handle_event(e) }
          poll if data['events'].size >= data['limit'].to_i
          if was_offline
            when_idle { pump_pushes }
            run_jobs
          end
        elsif st == 401
          TeamHub.auth_expired
        else
          @status = :offline
        end
        notify
      end
    end

    def status_text
      root = (@model.active_path || []).first
      return "يعدّل: #{display_name(root)}" if root && @eid_to_oid[root.entityID]
      n = @locks.count { |_, uid| uid == my_id }
      n.positive? ? "حاجز #{n} عنصر" : nil
    rescue StandardError
      nil
    end

    def handle_event(e)
      seq = e['seq'].to_i
      return if seq <= @seq
      @seq = seq
      u = e['user']
      @users[u['id']] = u if u
      p = e['payload'] || {}
      case e['type']
      when 'object'
        oid = p['oid']
        @objects[oid] = p
        unless mine?(oid) && p['updated_by'] == my_id
          if p['deleted']
            enqueue(p) if local_exists?(p)
          elsif local_rev(p) != p['rev']
            enqueue(p)
          end
        end
      when 'lock'
        p['oids'].each { |o| @locks[o] = p['user_id'] }
        when_idle { apply_local_locks(p['oids']) }
      when 'unlock'
        lost = p['oids'].select { |o| mine?(o) }
        lost = [] if %w[release deleted].include?(p['reason'])
        p['oids'].each { |o| @locks.delete(o) }
        unless lost.empty?
          names = lost.map { |o| object_label(o) }.first(3).join('، ')
          TeamHub.flash("انفك حجزك على: #{names}")
        end
        when_idle { apply_local_locks(p['oids']) }
      when 'chat'
        TeamHub.chat_received(e) unless u && u['id'] == my_id
      end
      @events << e
      @events.shift while @events.size > 150
    end

    # ------------------------------------------------------------ index

    def trackable?(e)
      (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) && e.valid?
    end

    def top_level?(e)
      e.parent == @model
    rescue StandardError
      false
    end

    def rebuild_index
      @index.clear
      @eid_to_oid.clear
      @def_index.clear
      @model.definitions.each do |d|
        next if d.group? || d.image?
        did = d.get_attribute(DICT, 'did')
        @def_index[did] ||= d if did
      end
      @model.entities.each do |e|
        next unless trackable?(e)
        oid = e.get_attribute(DICT, 'oid')
        if oid.nil? || @index.key?(oid)
          @added << e unless viewer?
        else
          index_entity(e)
        end
      end
    end

    def index_entity(e)
      oid = e.get_attribute(DICT, 'oid')
      @index[oid] = e
      @eid_to_oid[e.entityID] = oid
    end

    def live_entity(oid)
      e = @index[oid]
      e && e.valid? ? e : nil
    end

    def live_def(did)
      d = did && @def_index[did]
      d && d.valid? ? d : nil
    end

    def did_of(oid)
      oid.sub(/\Ad_/, '')
    end

    def local_exists?(obj)
      obj['kind'] == 'definition' ? !live_def(did_of(obj['oid'])).nil? : !live_entity(obj['oid']).nil?
    end

    def local_rev(obj)
      holder = obj['kind'] == 'definition' ? live_def(did_of(obj['oid'])) : live_entity(obj['oid'])
      holder ? holder.get_attribute(DICT, 'rev', -1) : -1
    end

    def reconcile_with_server
      defs, rest = @objects.values.partition { |o| o['kind'] == 'definition' }
      (defs + rest).each do |o|
        oid = o['oid']
        if mine?(oid) && local_exists?(o)
          # Reserved by me: my local copy is the truth. Re-push it.
          if o['kind'] == 'definition'
            @def_dirty[did_of(oid)] = true
          else
            @content_dirty[oid] = true
          end
          next
        end
        if o['deleted']
          enqueue(o) if local_exists?(o)
        elsif local_rev(o) != o['rev']
          enqueue(o)
        end
      end
      @index.each { |oid, ent| @added << ent unless @objects[oid] }
    end

    # ------------------------------------------------------------ observers

    def on_commit
      return if @suspended.positive? || !@loaded
      root = (@model.active_path || []).first
      if root && (oid = @eid_to_oid[root.entityID])
        if root.is_a?(Sketchup::Group)
          @content_dirty[oid] = true
        elsif (did = root.definition.get_attribute(DICT, 'did'))
          @def_dirty[did] = true
        end
      end
      schedule_scan
    end

    def on_undo
      return if @suspended.positive? || !@loaded
      @after_undo = true
      schedule_scan
    end

    def on_added(e)
      return if @suspended.positive? || !@loaded
      @added << e if e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
      schedule_scan
    end

    def on_removed(eid)
      return if @suspended.positive? || !@loaded
      @removed << eid
      schedule_scan
    end

    def on_tool_state(state)
      @tool_busy = state.to_i != 0
      @busy_since = Time.now if @tool_busy
    end

    def on_active_path
      return if @suspended.positive? || !@loaded
      root = (@model.active_path || []).first
      return unless root
      oid = @eid_to_oid[root.entityID]
      return unless oid
      unless mine?(oid) || @new_local[oid]
        UI.start_timer(0, false) { @model.close_active rescue nil }
        TeamHub.flash("احجز «#{display_name(root)}» قبل ما تعدل عليه")
        return
      end
      return unless root.is_a?(Sketchup::ComponentInstance)
      did = root.definition.get_attribute(DICT, 'did')
      d_oid = did && "d_#{did}"
      return unless d_oid && @objects[d_oid] && !@objects[d_oid]['deleted'] && !mine?(d_oid)
      lock_request([d_oid]) do |_granted, denied|
        next if denied.empty?
        holder = denied.first['user']
        UI.start_timer(0, false) { @model.close_active rescue nil }
        TeamHub.flash("تعريف المكوّن «#{root.definition.name}» محجوز من #{holder ? holder['display_name'] : 'عضو ثاني'}. تكدر تحركه، بس ما تكدر تعدل داخله.")
      end
    end

    # ------------------------------------------------------------ idle gate

    def busy?
      @tool_busy && (Time.now - @busy_since) < 15
    end

    # Runs the block when no tool is mid-operation, so sync edits never land
    # inside (or break) a Move/PushPull/Line operation the user is doing.
    def when_idle(&blk)
      return if @stopped
      @idle_queue << blk
      pump_idle
    end

    def pump_idle(delay = 0.05)
      return if @idle_timer || @stopped
      @idle_timer = UI.start_timer(delay, false) do
        @idle_timer = nil
        if busy?
          pump_idle(0.4)
        else
          queue = @idle_queue
          @idle_queue = []
          queue.each { |b| guard { b.call } }
          pump_idle unless @idle_queue.empty?
        end
      end
    end

    def model_op(name)
      @suspended += 1
      @model.start_operation(name, true, false, true)
      ok = false
      begin
        yield
        ok = true
      ensure
        ok ? @model.commit_operation : @model.abort_operation
        @suspended -= 1
      end
    end

    def guard
      yield
    rescue StandardError => e
      @last_error = e.message
      TeamHub.log_error(e)
      nil
    end

    # ------------------------------------------------------------ scan & push

    def schedule_scan(delay = SCAN_DELAY)
      return if @stopped
      UI.stop_timer(@scan_timer) if @scan_timer
      @scan_timer = UI.start_timer(delay, false) do
        @scan_timer = nil
        when_idle { scan }
      end
    end

    def scan
      return unless @loaded && !@stopped
      process_removed
      if @after_undo
        @after_undo = false
        after_undo_reconcile
      end
      process_added
      return notify if viewer?

      @index.each do |oid, ent|
        next unless ent.valid? && (mine?(oid) || @new_local[oid])
        if ent.is_a?(Sketchup::ComponentInstance)
          did = ent.definition.get_attribute(DICT, 'did')
          if did.nil? || (live_def(did) && live_def(did) != ent.definition)
            model_op('Team Hub') { ensure_did(ent.definition) } # after "Make Unique"
          end
        end
        mfp = meta_fp(ent)
        cfp = content_fp(ent)
        content = @content_dirty.delete(oid) || @new_local[oid] ||
                  (@content_fp.key?(oid) && @content_fp[oid] != cfp)
        server = @objects[oid]
        next unless content || server.nil? || server['deleted'] || @meta_fp[oid] != mfp
        request_push(oid, content ? true : false)
      end

      @def_index.each do |did, d|
        next unless d.valid?
        d_oid = "d_#{did}"
        server = @objects[d_oid]
        if mine?(d_oid)
          fp = defn_fp(d)
          dirty = @def_dirty.delete(did) || (@content_fp.key?(d_oid) && @content_fp[d_oid] != fp)
          request_push(d_oid, true) if dirty
        elsif @def_dirty.delete(did)
          if server.nil? || server['deleted']
            request_push(d_oid, true)
          else
            TeamHub.flash("عدّلت داخل «#{d.name}» بدون ما تحجز تعريفه، فالتعديل ما راح يوصل للفريق. رجّعت النسخة الأصلية.")
            enqueue(server.merge('force' => true))
          end
        end
      end
      @def_dirty.clear

      @raw_count = count_raw_geometry
      apply_local_locks
      notify
    end

    def process_removed
      ids = @removed.uniq
      @removed.clear
      ids.each do |eid|
        oid = @eid_to_oid[eid]
        next unless oid
        ent = @index[oid]
        next if ent && ent.valid? && ent.entityID != eid
        @eid_to_oid.delete(eid)
        @index.delete(oid) if ent.nil? || !ent.valid?
        @push_wanted.delete(oid)
        @content_dirty.delete(oid)
        next if @new_local.delete(oid) && @objects[oid].nil?
        server = @objects[oid]
        next unless server && !server['deleted']
        if mine?(oid)
          push_delete(oid)
        else
          enqueue(server.merge('force' => true)) # not allowed → put it back
        end
      end
    end

    def after_undo_reconcile
      rebuild_index
      @objects.each_value do |o|
        oid = o['oid']
        if mine?(oid)
          if local_exists?(o)
            o['kind'] == 'definition' ? (@def_dirty[did_of(oid)] = true) : (@content_dirty[oid] = true)
          elsif !o['deleted'] && o['kind'] != 'definition'
            push_delete(oid)
          end
          next
        end
        if o['deleted'] && local_exists?(o)
          if o['updated_by'] == my_id && o['kind'] != 'definition' && !viewer?
            # I deleted it and then pressed Undo: bring it back for everyone.
            @new_local[oid] = true
            @content_dirty[oid] = true
            @locks[oid] = my_id
          else
            enqueue(o)
          end
        elsif !o['deleted'] && local_rev(o) != o['rev']
          enqueue(o)
        end
      end
    end

    def process_added
      list = @added.uniq.select { |e| trackable?(e) && top_level?(e) }
      @added.clear
      return if list.empty? || viewer?
      model_op('Team Hub: عنصر جديد') do
        list.each do |e|
          oid = e.get_attribute(DICT, 'oid')
          other = oid && @index[oid]
          if oid.nil? || (other && other != e && other.valid?)
            oid = "o#{SecureRandom.hex(10)}"
            e.set_attribute(DICT, 'oid', oid)
          end
          e.delete_attribute(DICT, 'rev')
          e.locked = false if e.locked?
          ensure_did(e.definition) if e.is_a?(Sketchup::ComponentInstance)
          index_entity(e)
          server = @objects[oid]
          if server.nil? || server['deleted']
            @new_local[oid] = true
          elsif !mine?(oid)
            # An existing object came back (e.g. undo) but it isn't mine.
            enqueue(server.merge('force' => true))
            next
          end
          @content_dirty[oid] = true
        end
      end
    end

    def ensure_did(defn)
      did = defn.get_attribute(DICT, 'did')
      if did.nil? || (live_def(did) && live_def(did) != defn)
        did = SecureRandom.hex(10)
        defn.set_attribute(DICT, 'did', did)
        defn.delete_attribute(DICT, 'rev')
      end
      @def_index[did] = defn
      did
    end

    def meta_fp(ent)
      t = ent.transformation.to_a.map { |v| v.round(6) }
      did = ent.is_a?(Sketchup::ComponentInstance) ? ent.definition.get_attribute(DICT, 'did') : nil
      [t, ent.name, ent.layer.name, ent.material&.name, ent.hidden?, did]
    end

    def content_fp(ent)
      defn_fp(ent.definition)
    end

    def defn_fp(d)
      b = d.bounds
      [d.entities.length, b.min.to_a.map { |v| v.round(5) }, b.max.to_a.map { |v| v.round(5) }]
    end

    def snapshot_fp(oid)
      if oid.start_with?('d_')
        d = live_def(did_of(oid))
        @content_fp[oid] = defn_fp(d) if d
      elsif (e = live_entity(oid))
        @meta_fp[oid] = meta_fp(e)
        @content_fp[oid] = content_fp(e)
      end
    end

    def request_push(oid, content)
      @push_wanted[oid] = (@push_wanted[oid] || false) || content
      when_idle { pump_pushes }
    end

    def pump_pushes
      return unless connected? && !@stopped
      @delete_wanted.keys.each { |oid| @delete_wanted.delete(oid); push_delete(oid) }
      @push_wanted.keys.each do |oid|
        next if @pushing[oid]
        content = @push_wanted.delete(oid)
        push_now(oid, content)
      end
    end

    def push_now(oid, content)
      if oid.start_with?('d_')
        d = live_def(did_of(oid))
        return unless d
        server = @objects[oid]
        body = {
          'kind' => 'definition', 'name' => d.name, 'layer' => '',
          'meta' => { 'name' => d.name, 'description' => d.description },
          'data' => export_definition(d),
        }
        fp = defn_fp(d)
        mfp = nil
      else
        ent = live_entity(oid)
        return unless ent
        server = @objects[oid]
        if ent.is_a?(Sketchup::ComponentInstance)
          did = ent.definition.get_attribute(DICT, 'did')
          return request_push(oid, content) if did.nil?
          d_oid = "d_#{did}"
          if @objects[d_oid].nil? || @objects[d_oid]['deleted']
            # The definition goes first; this instance follows when it lands.
            @push_wanted[oid] = content
            push_now(d_oid, true) unless @pushing[d_oid]
            return
          end
        end
        kind = ent.is_a?(Sketchup::Group) ? 'group' : 'component'
        meta = { 't' => ent.transformation.to_a, 'material' => ent.material&.name, 'hidden' => ent.hidden?,
                 'iname' => ent.name.to_s }
        if kind == 'component'
          meta['def'] = ent.definition.get_attribute(DICT, 'did')
          meta['def_name'] = ent.definition.name
        end
        # 'name' is the label everyone sees; meta.iname is the entity's own name.
        body = { 'kind' => kind, 'name' => display_name(ent), 'layer' => ent.layer.name, 'meta' => meta }
        if kind == 'group' && (content || server.nil? || server['deleted'] || server['blob'].nil?)
          body['data'] = export_definition(ent.definition)
        end
        fp = content_fp(ent)
        mfp = meta_fp(ent)
      end
      body['base_rev'] = server['rev'] if server && !server['deleted']

      @pushing[oid] = true
      notify
      @client.request(:post, "/api/projects/#{pid}/objects/#{oid}", body, timeout: 600) do |st, data|
        @pushing.delete(oid)
        next if @stopped
        handle_push_result(oid, st, data, content, mfp, fp)
        when_idle { pump_pushes }
        notify
      end
    end

    def handle_push_result(oid, st, data, content, mfp, fp)
      case st
      when 200
        obj = data['object']
        @objects[oid] = obj
        @locks[oid] = my_id
        @new_local.delete(oid)
        @meta_fp[oid] = mfp if mfp
        @content_fp[oid] = fp if fp
        @status = :online
        holder = oid.start_with?('d_') ? live_def(did_of(oid)) : live_entity(oid)
        if holder.nil?
          push_delete(oid) unless oid.start_with?('d_') # deleted while uploading
        elsif @release_after.delete(oid) && !@push_wanted.key?(oid)
          send_unlock([oid])
        end
        if @mode == :upload && @push_wanted.empty? && @pushing.empty? && @new_local.empty?
          # Initial upload finished: hand everything over to the team.
          @mode = :resume
          release_all
          TeamHub.flash('انرفع الملف للمشروع. الفريق يكدر يحجز ويشتغل هسه.')
        end
      when 423
        @new_local.delete(oid)
        @release_after.delete(oid)
        holder = data && data['user']
        holder ? @locks[oid] = holder['id'] : @locks.delete(oid)
        TeamHub.flash("ما انرفع تعديلك على «#{object_label(oid)}»: #{holder ? "محجوز من #{holder['display_name']}" : 'مو محجوز إلك'}. رجّعت نسخة الفريق.")
        server = @objects[oid]
        enqueue(server.merge('force' => true)) if server && !server['deleted']
        when_idle { apply_local_locks([oid]) }
      when 409
        # Our base revision is stale but we still hold the reservation:
        # our copy is the newest, so retry on top of the server's revision.
        @objects[oid] = (@objects[oid] || {}).merge('rev' => data['rev'], 'deleted' => false) if data
        request_push(oid, content)
      when 401
        TeamHub.auth_expired
      when 0
        @status = :offline
        @push_wanted[oid] = (@push_wanted[oid] || false) || content
      else
        @last_error = "upload #{st}: #{data && data['error']}"
        TeamHub.flash("خطأ برفع «#{object_label(oid)}»: #{data && data['error']}")
      end
    end

    def push_delete(oid)
      server = @objects[oid]
      return unless server && !server['deleted']
      @client.request(:delete, "/api/projects/#{pid}/objects/#{oid}?base_rev=#{server['rev']}") do |st, data|
        next if @stopped
        case st
        when 200
          @objects[oid] = data['object'] if data && data['object'].is_a?(Hash) && data['object']['oid']
          @locks.delete(oid)
        when 0
          @delete_wanted[oid] = true
          @status = :offline
        else
          TeamHub.flash("ما انحذف «#{object_label(oid)}» من المشروع (#{data && data['error']}). رجّعته.")
          enqueue(server.merge('force' => true))
        end
        notify
      end
    end

    def export_definition(defn)
      out = File.join(@temp, "save_#{SecureRandom.hex(6)}.skp")
      ok = TeamHub.save_definition(defn, out)
      raise "تعذر حفظ «#{defn.name}»" unless ok && File.exist?(out)
      [File.binread(out)].pack('m0')
    ensure
      File.delete(out) if out && File.exist?(out)
    end

    # ------------------------------------------------------------ pull & apply

    def enqueue(obj)
      @jobs.reject! { |j| j['oid'] == obj['oid'] }
      @jobs << obj
      run_jobs
    end

    def run_jobs
      return if @job_running || @jobs.empty? || @stopped
      obj = @jobs.shift
      @job_running = true
      done = lambda do
        @job_running = false
        notify
        UI.start_timer(0, false) { guard { run_jobs } }
      end
      apply = lambda do |path|
        when_idle do
          guard { apply_object(obj, path) }
          done.call
        end
      end
      if obj['deleted'] || obj['kind'] == 'component'
        apply.call(nil)
        return
      end
      cache = File.join(@temp, 'blobs', "#{obj['blob']}.skp")
      return apply.call(cache) if File.exist?(cache)

      @client.request(:get, "/api/blobs/#{obj['blob']}?b64=1", nil, timeout: 600) do |st, data|
        next if @stopped
        if st == 200 && data && data['data']
          File.binwrite(cache, data['data'].unpack1('m0'))
          apply.call(cache)
        else
          @status = :offline if st.zero?
          @jobs.unshift(obj) unless @jobs.any? { |j| j['oid'] == obj['oid'] }
          @job_running = false
          UI.start_timer(5, false) { guard { run_jobs } }
          notify
        end
      end
    end

    def apply_object(obj, path)
      return if @stopped
      oid = obj['oid']
      return if mine?(oid) && local_exists?(obj) && !obj['force']
      model_op('Team Hub: تحديث من الفريق') do
        case obj['kind']
        when 'definition' then apply_definition(obj, path)
        when 'group' then apply_group(obj, path)
        else apply_component(obj)
        end
      end
      refresh_overlay
    end

    def apply_definition(obj, path)
      did = did_of(obj['oid'])
      old = live_def(did)
      if obj['deleted']
        if old && old.instances.empty?
          @def_index.delete(did)
          remove_definitions([old])
        end
        return
      end
      newdef = load_definition(path)
      @def_index[did] = newdef
      if old && old != newdef
        nested = nested_definitions(old)
        old.instances.to_a.each do |inst|
          was = inst.locked?
          inst.locked = false if was
          inst.definition = newdef
          inst.locked = true if was
        end
        remove_definitions([old] + nested)
      end
      meta = obj['meta'] || {}
      name = meta['name'].to_s
      begin
        newdef.name = name unless name.empty? || newdef.name == name
      rescue StandardError
        nil
      end
      newdef.description = meta['description'].to_s
      newdef.set_attribute(DICT, 'did', did)
      newdef.set_attribute(DICT, 'rev', obj['rev'])
    end

    def apply_group(obj, path)
      oid = obj['oid']
      old = live_entity(oid)
      if obj['deleted']
        erase_tracked(old)
        return
      end
      defn = load_definition(path)
      grp = @model.entities.add_group
      grp.entities.add_instance(defn, IDENTITY).explode
      remove_definitions([defn])
      t = (obj['meta'] || {})['t']
      grp.transformation = Geom::Transformation.new(t) if t.is_a?(Array) && t.size == 16
      finish_entity(grp, obj, old)
    end

    def apply_component(obj)
      oid = obj['oid']
      old = live_entity(oid)
      if obj['deleted']
        erase_tracked(old)
        return
      end
      meta = obj['meta'] || {}
      defn = live_def(meta['def'])
      unless defn
        d = @objects["d_#{meta['def']}"]
        if d && !d['deleted']
          # Definition hasn't arrived yet: fetch it, then this instance again.
          enqueue(d)
          enqueue(obj)
        end
        return
      end
      tr = meta['t'].is_a?(Array) && meta['t'].size == 16 ? Geom::Transformation.new(meta['t']) : IDENTITY
      if old.is_a?(Sketchup::ComponentInstance)
        old.locked = false
        old.definition = defn unless old.definition == defn
        old.transformation = tr
        ent = old
      else
        ent = @model.entities.add_instance(defn, tr)
      end
      finish_entity(ent, obj, old)
    end

    def finish_entity(ent, obj, old)
      oid = obj['oid']
      meta = obj['meta'] || {}
      ent.name = (meta.key?('iname') ? meta['iname'] : obj['name']).to_s
      layer = obj['layer'].to_s
      ent.layer = (@model.layers[layer] || @model.layers.add(layer)) unless layer.empty?
      mat = meta['material']
      ent.material = mat ? @model.materials[mat] : nil
      ent.hidden = meta['hidden'] ? true : false
      ent.set_attribute(DICT, 'oid', oid)
      ent.set_attribute(DICT, 'rev', obj['rev'])
      erase_tracked(old) if old && old != ent
      index_entity(ent)
      ent.locked = !mine?(oid)
    end

    def erase_tracked(ent)
      return unless ent && ent.valid?
      oid = @eid_to_oid.delete(ent.entityID)
      @index.delete(oid) if oid && @index[oid] == ent
      defs = ent.is_a?(Sketchup::Group) ? [ent.definition] + nested_definitions(ent.definition) : []
      ent.locked = false if ent.locked?
      ent.erase!
      remove_definitions(defs)
    end

    def nested_definitions(defn, acc = [])
      defn.entities.each do |e|
        next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        d = e.definition
        next if acc.include?(d)
        acc << d
        nested_definitions(d, acc)
      end
      acc
    end

    # Removes definitions left unused by a replace, parents first.
    def remove_definitions(defs)
      defs = defs.compact.uniq
      synced = @def_index.values
      loop do
        removed = false
        defs.each do |d|
          next unless d.valid? && d.instances.empty? && !synced.include?(d)
          begin
            @model.definitions.remove(d)
            removed = true
          rescue StandardError
            nil
          end
        end
        break unless removed
      end
    end

    def load_definition(path)
      tmp = File.join(@temp, "load_#{SecureRandom.hex(6)}.skp")
      FileUtils.cp(path, tmp)
      defn = @model.definitions.load(tmp)
      raise 'تعذر فتح ملف العنصر' unless defn
      defn
    ensure
      begin
        File.delete(tmp) if tmp && File.exist?(tmp)
      rescue StandardError
        nil
      end
    end

    # ------------------------------------------------------------ locks

    def apply_local_locks(oids = nil)
      stamp = []
      list = (oids || @index.keys).filter_map do |oid|
        e = live_entity(oid)
        next unless e
        want = !(mine?(oid) || @new_local[oid])
        server = @objects[oid]
        # Released after my own last upload: my copy *is* that revision.
        if want && server && !server['deleted'] && server['updated_by'] == my_id &&
           e.get_attribute(DICT, 'rev') != server['rev'] && !@pushing[oid] && !@push_wanted.key?(oid)
          stamp << [e, server['rev']]
        end
        [e, want] if e.locked? != want
      end
      if oids.nil?
        @def_index.each do |did, d|
          d_oid = "d_#{did}"
          server = @objects[d_oid]
          next unless d.valid? && server && !server['deleted'] && !mine?(d_oid) && server['updated_by'] == my_id
          next if d.get_attribute(DICT, 'rev') == server['rev'] || @pushing[d_oid] || @push_wanted.key?(d_oid)
          stamp << [d, server['rev']]
        end
      end
      unless list.empty? && stamp.empty?
        model_op('Team Hub: الحجوزات') do
          list.each { |e, w| e.locked = w }
          stamp.each { |e, rev| e.set_attribute(DICT, 'rev', rev) }
        end
      end
      refresh_overlay
    end

    def lock_request(oids, &blk)
      @client.request(:post, "/api/projects/#{pid}/locks", { 'oids' => oids }) do |st, data|
        next if @stopped
        if st == 200 && data
          data['granted'].each { |o| @locks[o] = my_id }
          data['denied'].each { |d| @locks[d['oid']] = d['user']['id'] if d['user'] }
          blk&.call(data['granted'], data['denied'])
        else
          TeamHub.flash('تعذر الاتصال بالسيرفر')
          blk&.call([], [])
        end
        notify
      end
    end

    def oids_for(entities, include_defs: true)
      oids = []
      entities.each do |e|
        next unless trackable?(e) && top_level?(e)
        oid = @eid_to_oid[e.entityID]
        next unless oid
        oids << oid
        next unless include_defs && e.is_a?(Sketchup::ComponentInstance)
        did = e.definition.get_attribute(DICT, 'did')
        oids << "d_#{did}" if did && @objects["d_#{did}"]
      end
      oids.uniq
    end

    def reserve(entities)
      return TeamHub.flash('حسابك مشاهدة فقط') if viewer?
      oids = oids_for(entities)
      return TeamHub.flash('حدد Group أو Component من الموديل أول') if oids.empty?
      lock_request(oids) do |granted, denied|
        granted.each do |oid|
          server = @objects[oid]
          if server && !server['deleted'] && local_rev(server) != server['rev']
            enqueue(server.merge('force' => true)) # get the latest before editing
          end
          snapshot_fp(oid)
        end
        when_idle { apply_local_locks }
        unless denied.empty?
          names = denied.reject { |d| d['oid'].start_with?('d_') }.map do |d|
            "«#{object_label(d['oid'])}» (#{d['user'] ? d['user']['display_name'] : '؟'})"
          end
          TeamHub.flash("محجوز من غيرك: #{names.first(4).join('، ')}") unless names.empty?
        end
        n = granted.count { |o| !o.start_with?('d_') }
        TeamHub.flash("حجزت #{n} عنصر. هسه تكدر تعدل عليهم.") if n.positive?
      end
    end

    def release(oids)
      oids = oids.select { |o| mine?(o) }
      return TeamHub.flash('ماكو حجوزات إلك بالتحديد') if oids.empty?
      scan if @loaded && !busy? # flush pending edits first
      pending = oids.select { |o| @pushing[o] || @push_wanted.key?(o) }
      pending.each { |o| @release_after[o] = true }
      ready = oids - pending
      send_unlock(ready) unless ready.empty?
    end

    def release_entities(entities)
      release(oids_for(entities))
    end

    def release_all
      release(@locks.select { |_, uid| uid == my_id }.keys)
    end

    def send_unlock(oids)
      @client.request(:post, "/api/projects/#{pid}/unlock", { 'oids' => oids }) do |st, data|
        next if @stopped
        if st == 200 && data
          data['released'].each { |o| @locks.delete(o) }
          when_idle { apply_local_locks }
        else
          TeamHub.flash('تعذر إلغاء الحجز، راح أحاول من يرجع الاتصال')
          oids.each { |o| @release_after[o] = true }
        end
        notify
      end
    end

    def resync
      @jobs.clear
      load_state
    end

    def chat(text)
      @client.request(:post, "/api/projects/#{pid}/chat", { 'text' => text }) do |st, _|
        TeamHub.flash('ما انرسلت الرسالة') unless st == 200
        poll
      end
    end

    def focus(oid)
      e = live_entity(oid)
      return unless e
      @model.selection.clear
      @model.selection.add(e)
      @model.active_view.zoom(e)
    end

    # ------------------------------------------------------------ display

    def display_name(e)
      n = e.name.to_s
      n = e.definition.name.to_s if n.empty? && e.is_a?(Sketchup::ComponentInstance)
      n = "مجموعة · #{e.layer.display_name}" if n.empty?
      n
    rescue StandardError
      '؟'
    end

    def object_label(oid)
      if oid.start_with?('d_')
        d = live_def(did_of(oid))
        return d ? d.name : (@objects.dig(oid, 'name') || oid)
      end
      e = live_entity(oid)
      e ? display_name(e) : (@objects.dig(oid, 'name').to_s.empty? ? oid : @objects.dig(oid, 'name'))
    end

    def count_raw_geometry
      @model.entities.count { |e| e.is_a?(Sketchup::Face) || e.is_a?(Sketchup::Edge) }
    end

    def color_of(uid)
      hex = (@users[uid] || {})['color'].to_s.delete('#')
      return Sketchup::Color.new(200, 60, 60) unless hex.size == 6
      Sketchup::Color.new(hex[0, 2].to_i(16), hex[2, 2].to_i(16), hex[4, 2].to_i(16))
    end

    def refresh_overlay
      items = []
      @index.each do |oid, e|
        next unless e.valid?
        uid = @locks[oid]
        if mine?(oid) || @new_local[oid]
          items << [e, color_of(my_id), 'أنت', true]
        elsif uid
          items << [e, color_of(uid), (@users[uid] || {})['display_name'] || '؟', false]
        end
      end
      @overlay_items = items
      @model.active_view.invalidate
    rescue StandardError
      nil
    end

    def overlay_items
      @overlay_items
    end

    def notify
      TeamHub.panel_refresh
    end

    def snapshot
      objs = @index.filter_map do |oid, e|
        next unless e.valid?
        {
          oid: oid,
          name: display_name(e),
          kind: e.is_a?(Sketchup::Group) ? 'group' : 'component',
          layer: (e.layer.display_name rescue ''),
          lock: @locks[oid],
          mine: mine?(oid) || @new_local[oid] ? true : false,
          rev: @objects.dig(oid, 'rev'),
          pending: (@push_wanted.key?(oid) || @pushing[oid]) ? true : false,
        }
      end
      objs.sort_by! { |o| [o[:mine] ? 0 : (o[:lock] ? 1 : 2), o[:name].downcase] }
      {
        connected: true,
        status: @status,
        loaded: @loaded,
        project: @project,
        me: @me,
        server: @client.server,
        online: @online,
        users: @users.values,
        objects: objs.first(1500),
        total: objs.size,
        my_count: objs.count { |o| o[:mine] },
        locked_count: @locks.size,
        downloads: @jobs.size + (@job_running ? 1 : 0),
        uploads: @push_wanted.size + @pushing.size,
        raw_geometry: @raw_count,
        events: @events.last(80),
        last_error: @last_error,
      }
    end
  end

  # ---------------------------------------------------------------- observers

  class ModelObs < Sketchup::ModelObserver
    def initialize(session)
      (@s = session)
    end
    def onTransactionCommit(_model)
      @s.guard { @s.on_commit }
    end
    def onTransactionUndo(_model)
      @s.guard { @s.on_undo }
    end
    def onTransactionRedo(_model)
      @s.guard { @s.on_undo }
    end
    def onActivePathChanged(_model)
      @s.guard { @s.on_active_path }
    end
  end

  class EntitiesObs < Sketchup::EntitiesObserver
    def initialize(session)
      (@s = session)
    end
    def onElementAdded(_entities, entity)
      @s.guard { @s.on_added(entity) }
    end
    def onElementRemoved(_entities, entity_id)
      @s.guard { @s.on_removed(entity_id) }
    end
  end

  class ToolsObs < Sketchup::ToolsObserver
    def initialize(session)
      (@s = session)
    end
    def onToolStateChanged(_tools, _name, _id, state)
      @s.on_tool_state(state)
    end
    def onActiveToolChanged(_tools, _name, _id)
      @s.on_tool_state(0)
    end
  end
end
