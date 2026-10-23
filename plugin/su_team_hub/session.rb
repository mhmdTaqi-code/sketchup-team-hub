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
    POLL_INTERVAL = 1.0
    SWEEP_INTERVAL = 3.0 # full check of every object for local changes
    SCAN_DELAY = 0.0 # check right after each operation
    MAX_PARALLEL_PUSHES = 4
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
      @touched = {}        # oid => true: may have changed locally, check on next scan
      @recent = {}         # oid => [user_id, time]: just changed by a teammate (shown in the viewport)
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
    # Everyone edits everything; a reservation is optional and only blocks others.
    def mine?(oid)
      !viewer? && (@locks[oid].nil? || @locks[oid] == my_id) && !claimed_by_other?(oid)
    end
    def reserved_by_me?(oid)
      @locks[oid] == my_id
    end
    def reserved_by_other?(oid)
      !@locks[oid].nil? && @locks[oid] != my_id
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
      attach_selection_observer
      @overlay = TeamHub.attach_overlay(@model, self)
      load_state
    end

    def stop
      @stopped = true
      UI.stop_timer(@poll_timer) if @poll_timer
      UI.stop_timer(@sweep_timer) if @sweep_timer
      UI.stop_timer(@tick_timer) if @tick_timer
      @poll_gen = (@poll_gen || 0) + 1
      UI.stop_timer(@scan_timer) if @scan_timer
      UI.stop_timer(@idle_timer) if @idle_timer
      @poll_timer = @scan_timer = @idle_timer = nil
      [[@model, @model_obs], [@model.entities, @ents_obs], [@model.tools, @tools_obs]].each do |target, obs|
        target.remove_observer(obs) if obs
      rescue StandardError
        nil
      end
      untrack_all
      detach_selection_observer
      stop_ws
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
          set_claims(data['claims']) if data['claims']
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
          @model.set_attribute(DICT, 'loose_rev', 0)
        end
      end
      rebuild_index
      baseline_all
      if @mode == :upload && !viewer?
        @index.each_key { |oid| @new_local[oid] = true; @content_dirty[oid] = true }
        @def_index.each_key { |did| @def_dirty[did] = true }
        @loose_base = nil
        @loose_dirty = true
      end
      ensure_tracking(LOOSE_OID)
      reconcile_with_server
      @raw_count = count_raw_geometry
      apply_local_locks
      schedule_scan(0)
    end

    # ------------------------------------------------------------ polling

    # start_polling / poll: long-poll loop, see realtime.rb

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
      u = e['user']
      @users[u['id']] = u if u
      p = e['payload'] || {}
      case e['type']
      when 'object'
        oid = p['oid']
        prev = @objects[oid]
        @objects[oid] = p
        unless p['updated_by'] == my_id # my own upload coming back
          @recent[oid] = [p['updated_by'], Time.now] unless p['kind'] == 'definition'
          if p['deleted']
            enqueue(p) if local_exists?(p)
          elsif local_rev(p) < p['rev']
            # Same contents as the copy I already have (a move/rotate/rename):
            # just update it in place, nothing to download.
            same = prev && p['kind'] == 'group' && p['blob'] && prev['blob'] == p['blob'] &&
                   local_rev(p) == prev['rev'].to_i
            ctx = ctx_for_object(p)
            if ctx && delta_live?(ctx)
              # Live deltas already brought these contents: never replace
              # (that would drop what someone is drawing right now).
              p['kind'] == 'group' ? enqueue(p.merge('meta_only' => true)) : stamp_rev_later(p)
            else
              enqueue(same ? p.merge('meta_only' => true) : p)
            end
          end
        end
      when 'lock'
        p['oids'].each { |o| @locks[o] = p['user_id'] }
        when_idle { apply_local_locks(p['oids']) }
      when 'unlock'
        lost = p['oids'].select { |o| reserved_by_me?(o) }
        lost = [] if %w[release deleted].include?(p['reason'])
        p['oids'].each { |o| @locks.delete(o) }
        unless lost.empty?
          names = lost.map { |o| object_label(o) }.first(3).join('، ')
          TeamHub.flash("انفك حجزك على: #{names}")
        end
        when_idle { apply_local_locks(p['oids']) }
      when 'delta'
        enqueue_delta(p, u) unless p['by'] == my_id
      when 'claim'
        p['oids'].each { |o| claims[o] = p['user_id'] }
        when_idle { apply_local_locks(p['oids']) } unless p['user_id'] == my_id
      when 'unclaim'
        p['oids'].each { |o| claims.delete(o) }
        when_idle { apply_local_locks(p['oids']) }
      when 'chat'
        TeamHub.chat_received(e) unless u && u['id'] == my_id
      end
      @events << e
      @events.shift while @events.size > 150
      @seq = seq
    end

    # ------------------------------------------------------------ index

    def trackable?(e)
      (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) && entity_valid?(e)
    end

    def entity_valid?(e)
      e && e.valid? && !e.deleted?
    rescue StandardError
      false
    end

    # Never invoke SketchUp's equality/hash methods on a deleted Ruby wrapper.
    def same_entity?(a, b)
      entity_valid?(a) && entity_valid?(b) && a.entityID == b.entityID
    end

    def top_level?(e)
      entity_valid?(e) && e.parent == @model
    rescue StandardError
      false
    end

    def rebuild_index
      @index.clear
      @eid_to_oid.clear
      @def_index.clear
      @model.definitions.each do |d|
        next unless entity_valid?(d)
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
      return unless trackable?(e)
      oid = e.get_attribute(DICT, 'oid')
      @eid_to_oid.delete_if { |eid, o| o == oid && eid != e.entityID }
      @index[oid] = e
      @eid_to_oid[e.entityID] = oid
    end

    def live_entity(oid)
      e = @index[oid]
      entity_valid?(e) ? e : nil
    end

    def live_def(did)
      d = did && @def_index[did]
      entity_valid?(d) ? d : nil
    end

    def did_of(oid)
      oid.sub(/\Ad_/, '')
    end

    def local_exists?(obj)
      if obj['oid'] == LOOSE_OID
        return !loose_entities.empty? || loose_rev < obj['rev'].to_i if obj['deleted']
        return (obj['meta'] || {})['empty'] || !loose_entities.empty?
      end
      obj['kind'] == 'definition' ? !live_def(did_of(obj['oid'])).nil? : !live_entity(obj['oid']).nil?
    end

    def local_rev(obj)
      return local_exists?(obj) ? loose_rev : -1 if obj['oid'] == LOOSE_OID
      holder = obj['kind'] == 'definition' ? live_def(did_of(obj['oid'])) : live_entity(obj['oid'])
      # No revision on the entity = it is as it was in the shared file (rev 0).
      holder ? holder.get_attribute(DICT, 'rev', 0).to_i : -1
    end

    # Everyone starts from the same shared file, so only what changed on the
    # server since then needs to come down. Objects the server has never seen
    # are simply unchanged since the shared file.
    def reconcile_with_server
      defs, rest = @objects.values.partition { |o| o['kind'] == 'definition' }
      (defs + rest).each do |o|
        if o['deleted']
          enqueue(o) if local_exists?(o)
        elsif !local_exists?(o) || local_rev(o) < o['rev'].to_i
          enqueue(o.merge('force' => true))
        end
      end
    end

    # Remember how every object looks now, so later scans only push real changes.
    def baseline_all
      with_root_coordinates do
        @index.each_key { |oid| guard { snapshot_fp(oid) } }
        @def_index.each_key { |did| guard { snapshot_fp("d_#{did}") } }
        guard { baseline_loose }
      end
    end

    # ------------------------------------------------------------ observers

    def on_commit
      return if @suspended.positive? || !@loaded
      flush_deltas(send: true)
      root = (@model.active_path || []).first
      if trackable?(root) && (oid = @eid_to_oid[root.entityID])
        if root.is_a?(Sketchup::Group)
          @content_dirty[oid] = true
        elsif (did = root.definition.get_attribute(DICT, 'did'))
          @def_dirty[did] = true
        end
        @touched[oid] = true
        note_activity(oid)
      end
      mark_loose_dirty if root.nil?
      # Moves, rotations, paint etc. on top-level objects act on the selection.
      sel = @model.selection.to_a
      sel.each do |e|
        next unless entity_valid?(e)
        o = @eid_to_oid[e.entityID]
        next unless o
        @touched[o] = true
        note_activity(o) if sel.size <= 30
      end
      schedule_scan
    end

    def on_modified(e)
      return if @suspended.positive? || !@loaded
      return unless entity_valid?(e)
      o = @eid_to_oid[e.entityID]
      return unless o
      @touched[o] = true
      schedule_scan
    end

    def on_undo
      return if @suspended.positive? || !@loaded
      flush_deltas(send: true)
      @after_undo = true
      schedule_scan
    end

    def on_added(e)
      return if @suspended.positive? || !@loaded
      @added << e if e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
      mark_loose_dirty if loose?(e)
      schedule_scan
    end

    def on_removed(eid)
      return if @suspended.positive? || !@loaded
      @removed << eid
      mark_loose_dirty unless @eid_to_oid.key?(eid)
      schedule_scan
    end

    def on_tool_state(state)
      @tool_busy = state.to_i != 0
      @busy_since = Time.now if @tool_busy
    end

    def on_active_path
      return if @suspended.positive? || !@loaded
      root = (@model.active_path || []).first
      return unless trackable?(root)
      oid = @eid_to_oid[root.entityID]
      return unless oid
      @touched[oid] = true
      (ctx = ctx_of_root(root)) && ensure_tracking(ctx)
      blocked = (reserved_by_other?(oid) || claimed_by_other?(oid)) ? oid : nil
      unless blocked
        note_activity(oid) do |holder|
          UI.start_timer(0, false) { @model.close_active rescue nil }
          TeamHub.flash("#{holder['display_name'] || 'عضو ثاني'} دا يعدّل على «#{display_name(root)}» هسه. انتظر يخلص.")
        end
      end
      if !blocked && root.is_a?(Sketchup::ComponentInstance)
        did = root.definition.get_attribute(DICT, 'did')
        blocked = "d_#{did}" if did && (reserved_by_other?("d_#{did}") || claimed_by_other?("d_#{did}"))
      end
      return unless blocked
      holder = @users[@locks[blocked]] || {}
      UI.start_timer(0, false) { @model.close_active rescue nil }
      TeamHub.flash("«#{display_name(root)}» محجوز من #{holder['display_name'] || 'عضو ثاني'}، ما تكدر تعدل عليه هسه.")
    end

    # ------------------------------------------------------------ idle gate

    def busy?
      @tool_busy && (Time.now - @busy_since) < 3
    end

    # Runs the block when no tool is mid-operation, so sync edits never land
    # inside (or break) a Move/PushPull/Line operation the user is doing.
    def when_idle(&blk)
      return if @stopped
      @idle_queue << blk
      pump_idle
    end

    def pump_idle(delay = 0)
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

    def suspend_sync
      @suspended_since ||= Time.now
      @suspended += 1
      begin
        yield
      ensure
        @suspended = [@suspended - 1, 0].max
        @suspended_since = nil if @suspended.zero?
      end
    end

    def model_op(name, rollback: true)
      suspend_sync do
        started = false
        @operation_depth = (@operation_depth || 0) + 1
        begin
          # Incoming replacements need their own transaction: aborting a
          # transparent operation also aborts the user's preceding operation.
          started = @model.start_operation(name, true, false, !rollback)
          raise 'Team Hub could not start operation' unless started
          result = yield
          raise 'Team Hub could not commit operation' unless @model.commit_operation
          started = false
          result
        rescue StandardError
          begin
            @model.abort_operation if started
          rescue StandardError => abort_error
            TeamHub.log_error(abort_error)
          end
          raise
        ensure
          @operation_depth -= 1
        end
      end
    end

    # Never take the user out of the group/component they are editing: the
    # few readings that depend on the edit context convert their coordinates
    # instead (see local_bbox), and whatever can't be read correctly while
    # inside waits until the user leaves (object_sighash, loose export).
    def with_root_coordinates
      yield
    end

    # The contents' box in the definition's own coordinates. While this
    # definition is open for editing SketchUp reports it in model space, so
    # undo the edit transform; if it is open further up the path we can't be
    # sure, so send no box (the receiver then doesn't align).
    def local_bbox(defn)
      fresh_bounds(defn)
      path = @model.active_path || []
      idx = path.index { |e| e.respond_to?(:definition) && e.definition == defn }
      return bbox_a(defn.bounds) if idx.nil?
      return nil unless idx == path.size - 1
      inv = @model.edit_transform.inverse
      bb = Geom::BoundingBox.new
      b = defn.bounds
      return nil if b.empty?
      (0..7).each { |i| bb.add(b.corner(i).transform(inv)) }
      bbox_a(bb)
    rescue StandardError
      nil
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
      with_root_coordinates { scan_at_root }
    end

    def scan_at_root
      process_removed
      if @after_undo
        @after_undo = false
        after_undo_reconcile
      end
      process_added
      return notify if viewer?

      # Only objects that may have changed: the one being edited, the selection,
      # anything SketchUp reported as modified, and new ones.
      candidates = @touched.keys | @new_local.keys | @content_dirty.keys
      candidates.each do |oid|
        begin
          @touched.delete(oid)
          ent = live_entity(oid)
          unless ent
            @content_dirty.delete(oid)
            @new_local.delete(oid)
            next
          end
          unless mine?(oid)
            # Changed here while someone else is on it (their claim arrived
            # late, or it was forced): never drop my version — keep it as a copy.
            next if viewer?
            changed = (@meta_fp.key?(oid) && @meta_fp[oid] != meta_fp(ent)) ||
                      (@content_fp.key?(oid) && @content_fp[oid] != content_fp(ent))
            if changed
              holder = @users[@locks[oid] || claims[oid]] || {}
              TeamHub.log_sync("REVERT #{oid} changed while #{holder['display_name']} has it")
              TeamHub.flash("«#{display_name(ent)}» يعدّل عليه #{holder['display_name'] || 'عضو ثاني'} هسه، فرجّعته مثل ما جان. انتظر يخلص.")
              server = @objects[oid]
              enqueue(server.merge('force' => true)) if server && !server['deleted']
              snapshot_fp(oid)
            end
            @content_dirty.delete(oid) if !changed || @objects[oid]
            next
          end
          if ent.is_a?(Sketchup::ComponentInstance)
            did = ent.definition.get_attribute(DICT, 'did')
            unless same_entity?(live_def(did), ent.definition)
              model_op('Team Hub') { ensure_did(ent.definition) } # after "Make Unique"
            end
            @def_dirty[ent.definition.get_attribute(DICT, 'did')] = true if @new_local[oid]
          end
          mfp = meta_fp(ent)
          cfp = content_fp(ent)
          content = @content_dirty.delete(oid) || @new_local[oid] ||
                    (@content_fp.key?(oid) && @content_fp[oid] != cfp)
          # A component copy has no contents of its own: drawing inside it changes
          # the shared definition (sent as deltas / definition checkpoint), not
          # the copy — so don't re-send its position for that.
          if content && ent.is_a?(Sketchup::ComponentInstance) && !@new_local[oid]
            @content_fp[oid] = cfp
            content = false
          end
          if content && delta_live?(oid) && editing_now?(oid) &&
             Time.now - ((@last_cp ||= {})[oid] || Time.at(0)) < CHECKPOINT_EVERY
            @content_dirty[oid] = true # deltas carry it live; full copy later
            content = false
          end
          next unless content || !@meta_fp.key?(oid) || @meta_fp[oid] != mfp
          (@last_cp ||= {})[oid] = Time.now if content
          request_push(oid, content ? true : false)
        rescue StandardError => e
          @touched[oid] = true
          @last_error = e.message
          TeamHub.log_error(e)
        end
      end

      @def_dirty.keys.each do |did|
        begin
          d = live_def(did)
          d_oid = "d_#{did}"
          open_here = d && ctx_of_root((@model.active_path || []).first) == d_oid
          if d && delta_live?(d_oid) && open_here &&
             Time.now - ((@last_cp ||= {})[d_oid] || Time.at(0)) < CHECKPOINT_EVERY
            next # deltas carry it live; full definition copy later
          end
          unless d
            @def_dirty.delete(did)
            next
          end
          if mine?(d_oid)
            (@last_cp ||= {})[d_oid] = Time.now
            request_push(d_oid, true)
            @def_dirty.delete(did)
          else
            holder = @users[@locks[d_oid]] || {}
            TeamHub.flash("تعريف «#{d.name}» محجوز من #{holder['display_name'] || 'عضو ثاني'}، فتعديلك داخله ما يوصل. رجّعت النسخة الأصلية.")
            server = @objects[d_oid]
            enqueue(server.merge('force' => true)) if server && !server['deleted']
            @def_dirty.delete(did)
          end
        rescue StandardError => e
          @last_error = e.message
          TeamHub.log_error(e)
        end
      end

      scan_loose
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
        next if entity_valid?(ent) && ent.entityID != eid
        @eid_to_oid.delete(eid)
        @index.delete(oid) unless entity_valid?(ent)
        @push_wanted.delete(oid)
        @content_dirty.delete(oid)
        next if @new_local.delete(oid) && @objects[oid].nil?
        server = @objects[oid]
        next if server && server['deleted']
        if mine?(oid)
          push_delete(oid) # also for objects unchanged since the shared file
        elsif server
          enqueue(server.merge('force' => true)) # reserved by someone else → put it back
        end
      end
    end

    # After Undo/Redo: my own changes that were undone go out as new versions;
    # a teammate's change that got undone along with mine comes back.
    def after_undo_reconcile
      rebuild_index
      @objects.each_value do |o|
        oid = o['oid']
        mine_last = o['updated_by'] == my_id
        if o['deleted']
          next unless local_exists?(o)
          if mine_last && o['kind'] != 'definition' && !viewer?
            @new_local[oid] = true # I deleted it, then pressed Undo
            @content_dirty[oid] = true
          else
            enqueue(o)
          end
        elsif local_exists?(o)
          if local_rev(o) < o['rev'].to_i
            if mine_last
              o['kind'] == 'definition' ? (@def_dirty[did_of(oid)] = true) : (@content_dirty[oid] = true)
            else
              enqueue(o.merge('force' => true))
            end
          end
        elsif o['kind'] == 'definition'
          enqueue(o.merge('force' => true))
        else
          mine_last && mine?(oid) ? push_delete(oid) : enqueue(o.merge('force' => true))
        end
      end
      @index.each_key { |oid| @touched[oid] = true }
    end

    def process_added
      list = @added.select { |e| trackable?(e) && top_level?(e) }.uniq { |e| e.entityID }
      @added.clear
      return if list.empty? || viewer?
      list.each do |e|
        begin
          model_op('Team Hub: عنصر جديد') do
            oid = e.get_attribute(DICT, 'oid')
            other = oid && live_entity(oid)
            next if same_entity?(other, e) && (@meta_fp.key?(oid) || @new_local[oid] || @content_dirty[oid])
            if oid.nil? || (other && !same_entity?(other, e))
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
        rescue StandardError => error
          @last_error = error.message
          TeamHub.log_error(error)
          guard { rebuild_index }
          @added << e if trackable?(e) && top_level?(e)
        end
      end
    end

    def ensure_did(defn)
      raise 'Team Hub definition was deleted' unless entity_valid?(defn)
      did = defn.get_attribute(DICT, 'did')
      if did.nil? || (live_def(did) && !same_entity?(live_def(did), defn))
        did = SecureRandom.hex(10)
        defn.set_attribute(DICT, 'did', did)
        defn.delete_attribute(DICT, 'rev')
      end
      @def_index[did] = defn
      @def_dirty[did] = true unless @objects["d_#{did}"] && !@objects["d_#{did}"]['deleted']
      did
    end

    def meta_fp(ent)
      t = t_of(ent, @eid_to_oid[ent.entityID]).map { |v| v.round(6) }
      did = ent.is_a?(Sketchup::ComponentInstance) ? ent.definition.get_attribute(DICT, 'did') : nil
      [t, ent.name, ent.layer.name, ent.material&.name, ent.hidden?, did]
    end

    def content_fp(ent)
      defn_fp(ent.definition)
    end

    def defn_fp(d)
      b = d.bounds
      [d.entities.length, b.min.to_a.map { |v| v.round(5) }, b.max.to_a.map { |v| v.round(5) },
       sighash_of_entities(d.entities, {}, true)]
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
        # A few uploads at a time: a 1,000-object model must not export and
        # send everything in one go (memory + a long UI freeze).
        break if @pushing.size >= MAX_PARALLEL_PUSHES
        next if @pushing[oid]
        next unless mine?(oid)
        next if (@push_retry_at ||= {})[oid] && Time.now < @push_retry_at[oid]
        content = @push_wanted.delete(oid)
        begin
          with_root_coordinates { push_now(oid, content) }
        rescue StandardError => e
          @pushing.delete(oid)
          @push_wanted[oid] = (@push_wanted[oid] || false) || content
          @push_retry_at[oid] = Time.now + 5
          @last_error = e.message
          TeamHub.log_error(e)
        end
      end
    end

    def push_now(oid, content)
      return push_loose if oid == LOOSE_OID
      if oid.start_with?('d_')
        d = live_def(did_of(oid))
        return unless d
        server = @objects[oid]
        body = {
          'kind' => 'definition', 'name' => d.name, 'layer' => '',
          'meta' => { 'name' => d.name, 'description' => d.description, 'bb' => local_bbox(d), 'bb_space' => 'local' },
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
          did = ensure_did(ent.definition) if did.nil?
          d_oid = "d_#{did}"
          if @objects[d_oid].nil? || @objects[d_oid]['deleted']
            # The definition goes first; this instance follows when it lands.
            @push_wanted[oid] = content
            push_now(d_oid, true) unless @pushing[d_oid]
            return
          end
        end
        kind = ent.is_a?(Sketchup::Group) ? 'group' : 'component'
        meta = { 't' => t_of(ent, oid), 'material' => ent.material&.name, 'hidden' => ent.hidden?,
                 'iname' => ent.name.to_s }
        if kind == 'component'
          meta['def'] = ent.definition.get_attribute(DICT, 'did')
          meta['def_name'] = ent.definition.name
        end
        # 'name' is the label everyone sees; meta.iname is the entity's own name.
        body = { 'kind' => kind, 'name' => display_name(ent), 'layer' => ent.layer.name, 'meta' => meta }
        if kind == 'group'
          meta['bb'] = local_bbox(ent.definition)
          meta['bb_space'] = 'local' if meta['bb']
        end
        if kind == 'group' && (content || server.nil? || server['deleted'] || server['blob'].nil?)
          body['data'] = export_definition(ent.definition)
        end
        fp = content_fp(ent)
        mfp = meta_fp(ent)
      end
      body['base_rev'] = local_rev('oid' => oid, 'kind' => oid.start_with?('d_') ? 'definition' : 'object') if server && !server['deleted']
      if body['data'] && (sh = object_sighash(oid))
        body['meta'] = (body['meta'] || {}).merge('sighash' => sh)
      end
      TeamHub.log_sync("PUSH #{oid} #{body['kind']} #{body['data'] ? "contents #{body['data'].size}b64" : 'position'} base r#{body['base_rev'].inspect}")

      @pushing[oid] = true
      notify
      @client.request(:post, "/api/projects/#{pid}/objects/#{oid}", body, timeout: 600) do |st, data|
        @pushing.delete(oid)
        next if @stopped
        begin
          handle_push_result(oid, st, data, content, mfp, fp)
        rescue StandardError => e
          @push_wanted[oid] = (@push_wanted[oid] || false) || content
          @push_retry_at[oid] = Time.now + 5
          @last_error = e.message
          TeamHub.log_error(e)
        ensure
          when_idle { pump_pushes }
          notify
        end
      end
    end

    def handle_push_result(oid, st, data, content, mfp, fp)
      case st
      when 200
        obj = data['object']
        latest = @objects[oid]
        @objects[oid] = obj unless latest && latest['rev'].to_i > obj['rev'].to_i
        TeamHub.log_sync("PUSHED #{oid} → r#{obj['rev']}")
        @new_local.delete(oid)
        @meta_fp[oid] = mfp if mfp
        @content_fp[oid] = fp if fp
        @status = :online
        holder = oid.start_with?('d_') ? live_def(did_of(oid)) : live_entity(oid)
        if holder.nil?
          push_delete(oid) unless oid.start_with?('d_') # deleted while uploading
        else
          # My copy now is that revision: remember it in the model, so reopening
          # the file doesn't download my own change again.
          rev = obj['rev']
          when_idle do
            model_op('Team Hub') do
              holder.set_attribute(DICT, 'rev', rev) if entity_valid?(holder) && holder.get_attribute(DICT, 'rev', 0).to_i < rev.to_i
            end
          end
          send_unlock([oid]) if @release_after.delete(oid) && !@push_wanted.key?(oid)
        end
        if @mode == :upload && @push_wanted.empty? && @pushing.empty? && @new_local.empty?
          # Initial upload finished: hand everything over to the team.
          @mode = :resume
          release_all
          TeamHub.flash('انرفع الملف للمشروع. الفريق يكدر يحجز ويشتغل هسه.')
        end
      when 423, 409
        if st == 409 || (data && data['error'] == 'being_edited')
          lost_race(oid, data)
          return
        end
        @new_local.delete(oid) if @objects[oid]
        @release_after.delete(oid)
        holder = data && data['user']
        holder ? @locks[oid] = holder['id'] : @locks.delete(oid)
        TeamHub.flash("ما انرفع تعديلك على «#{object_label(oid)}»: #{holder ? "محجوز من #{holder['display_name']}" : 'مو محجوز إلك'}. رجّعت نسخة الفريق.")
        server = @objects[oid]
        enqueue(server.merge('force' => true)) if server && !server['deleted']
        @push_wanted[oid] = true unless server
        when_idle { apply_local_locks([oid]) }
      when 401
        TeamHub.auth_expired
      when 0
        @status = :offline
        @push_wanted[oid] = (@push_wanted[oid] || false) || content
        (@push_retry_at ||= {})[oid] = Time.now + 5
      else
        @last_error = "upload #{st}: #{data && data['error']}"
        @push_wanted[oid] = (@push_wanted[oid] || false) || content
        (@push_retry_at ||= {})[oid] = Time.now + 10
        TeamHub.flash("خطأ برفع «#{object_label(oid)}»: #{data && data['error']}")
      end
    end

    def push_delete(oid)
      server = @objects[oid]
      return if server && server['deleted']
      @deleting ||= {}
      return if @deleting[oid]
      @deleting[oid] = true
      @client.request(:delete, "/api/projects/#{pid}/objects/#{oid}") do |st, data|
        @deleting.delete(oid)
        next if @stopped
        case st
        when 200
          if data && data['object'].is_a?(Hash) && data['object']['oid']
            o = data['object']
            @objects[oid] = o if @objects[oid].nil? || @objects[oid]['rev'].to_i <= o['rev'].to_i
          end
          @locks.delete(oid)
        when 0
          @delete_wanted[oid] = true
          @status = :offline
        else
          holder = data && data['user']
          TeamHub.flash("ما انحذف «#{object_label(oid)}»: #{holder ? "محجوز من #{holder['display_name']}" : data && data['error']}. رجّعته.")
          enqueue(server.merge('force' => true, '_refresh' => true)) if server
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
      queued = @jobs.find { |j| j['oid'] == obj['oid'] }
      return if queued && queued['rev'].to_i > obj['rev'].to_i
      if queued && queued['rev'].to_i == obj['rev'].to_i
        obj = queued.merge(obj)
        obj['force'] = true if queued['force']
        obj.delete('meta_only') if queued['force'] || obj['force']
      end
      @jobs.reject! { |j| j['oid'] == obj['oid'] }
      @jobs << obj.dup
      run_jobs
    end

    def defer_job(obj, delay)
      enqueue(obj.merge('_ready_at' => Time.now + delay))
    end

    def retry_job(obj, error)
      @last_error = error.message
      TeamHub.log_error(error)
      tries = obj['_attempt'].to_i + 1
      if tries <= 3
        TeamHub.log_sync("RETRY #{obj['oid']} r#{obj['rev']} attempt #{tries}/3: #{error.message}")
        defer_job(obj.merge('_attempt' => tries), 2 ** (tries - 1))
      else
        # Drop meta-only shortcuts and the cached file. Keep retrying at a slow
        # rate after the bounded fast retries; a failed revision is never done.
        TeamHub.log_sync("RETRY FULL #{obj['oid']} r#{obj['rev']}: #{error.message}")
        fresh = obj.merge('force' => true, '_redownload' => true, '_refresh' => true, '_attempt' => 0)
        fresh.delete('meta_only')
        defer_job(fresh, 30)
      end
    end

    # The conflict response contains a revision but no full object. Refresh the
    # descriptor using the existing state endpoint (also repairs missing deps).
    def refresh_for_job(obj, &done)
      @client.request(:get, "/api/projects/#{pid}/state", nil, timeout: 60) do |st, data|
        begin
          raise "refresh #{obj['oid']}: HTTP #{st}" unless st == 200 && data && data['objects']
          data['objects'].each do |o|
            prev = @objects[o['oid']]
            @objects[o['oid']] = o if prev.nil? || prev['rev'].to_i <= o['rev'].to_i
          end
          fresh = @objects[obj['oid']] || obj
          fresh = fresh.merge('force' => true, '_redownload' => true)
          fresh.delete('_refresh')
          defer_job(fresh, 0)
        rescue StandardError => e
          retry_job(obj, e)
        ensure
          done.call
        end
      end
    end

    def run_jobs
      return if @job_running || @jobs.empty? || @stopped
      ready = @jobs.index { |j| j['_ready_at'].nil? || j['_ready_at'] <= Time.now }
      unless ready
        unless @job_timer
          delay = [@jobs.map { |j| j['_ready_at'] }.min - Time.now, 0.1].max
          @job_timer = UI.start_timer(delay, false) do
            @job_timer = nil
            guard { run_jobs }
          end
        end
        return
      end
      obj = @jobs.delete_at(ready)
      @job_running = true
      @running_job = obj
      done = lambda do
        @job_running = false
        @running_job = nil
        UI.start_timer(0, false) { guard { run_jobs } }
        notify
      end
      return refresh_for_job(obj, &done) if obj['_refresh']
      if obj['kind'] == 'delta'
        when_idle do
          begin
            apply_delta(obj)
          rescue StandardError => e
            retry_job(obj, e)
          ensure
            done.call
          end
        end
        return
      end
      apply = lambda do |path|
        when_idle do
          begin
            apply_object(obj, path)
          rescue StandardError => e
            # Ruby indices aren't part of SketchUp's undo transaction. Rebuild
            # them after abort so retries never see wrappers from the rollback.
            guard { rebuild_index }
            retry_job(obj, e)
          ensure
            done.call
          end
        end
      end
      if obj['deleted'] || obj['kind'] == 'component' || (obj['meta_only'] && live_entity(obj['oid'])) ||
         (obj['kind'] == 'loose' && (obj['meta'] || {})['empty'])
        apply.call(nil)
        return
      end
      cache = File.join(@temp, 'blobs', "#{obj['blob']}.skp")
      raise "Missing blob for #{obj['oid']}" if obj['blob'].nil?
      return apply.call(cache) if File.exist?(cache) && !obj['_redownload']

      @client.request(:get, "/api/blobs/#{obj['blob']}?b64=1", nil, timeout: 600) do |st, data|
        if @stopped
          done.call
          next
        end
        begin
          raise "download #{obj['oid']}: HTTP #{st}" unless st == 200 && data && data['data']
          File.binwrite(cache, data['data'].unpack1('m0'))
          apply.call(cache)
        rescue StandardError => e
          @status = :offline if st.zero?
          retry_job(obj, e)
          done.call
        end
      end
    rescue StandardError => e
      retry_job(obj, e) if obj
      done.call if done
    end

    def apply_object(obj, path)
      return if @stopped
      oid = obj['oid']
      latest = @objects[oid]
      # A newer revision exists (often my own edit that won): this one is stale.
      if latest && latest['rev'].to_i > obj['rev'].to_i
        needed = latest['deleted'] ? local_exists?(latest) : local_rev(latest) < latest['rev'].to_i
        enqueue(latest.merge('force' => true)) if needed
        return
      end
      return if latest && latest['updated_by'] == my_id && !obj['force'] && local_rev(obj) >= obj['rev'].to_i
      # A queued local upload cannot wait on somebody else's claim while also
      # blocking that person's incoming version indefinitely.
      @push_wanted.delete(oid) if !mine?(oid) && !@pushing[oid]
      if editing_now?(oid) || @pushing[oid] || @push_wanted.key?(oid) ||
         (!obj['force'] && (@touched[oid] || @content_dirty[oid])) || placement_unsafe?(obj)
        # I'm in the middle of it (or inside a Group, where loose geometry
        # would land in the wrong place): apply a moment later.
        defer_job(obj, 2)
        return
      end
      if obj['kind'] == 'component' && !obj['deleted'] && !live_def((obj['meta'] || {})['def'])
        dep = @objects["d_#{(obj['meta'] || {})['def']}"]
        raise "Missing definition for #{oid}" unless dep && !dep['deleted']
        enqueue(dep.merge('force' => true))
        defer_job(obj, 2)
        return
      end
      with_root_coordinates do
        flush_deltas(send: true)
        ctx = ctx_for_object(obj)
        untrack(ctx) if ctx && !obj['meta_only']
        TeamHub.log_sync("APPLY #{oid} #{obj['kind']} r#{obj['rev']}#{obj['meta_only'] ? ' position' : ''}#{obj['deleted'] ? ' DELETE' : ''} from u#{obj['updated_by']}")
        model_op('Team Hub: تحديث من الفريق', rollback: true) do
          case obj['kind']
          when 'definition' then apply_definition(obj, path)
          when 'group' then obj['meta_only'] && live_entity(oid) ? apply_group_meta(obj) : apply_group(obj, path)
          when 'loose' then apply_loose(obj, path)
          else apply_component(obj)
          end
          raise "Apply left #{oid} missing" unless obj['deleted'] || local_exists?(obj)
          verify_applied(obj)
        end
        @content_dirty.delete(oid)
        @touched.delete(oid)
        @def_dirty.delete(did_of(oid)) if obj['kind'] == 'definition'
        if obj['kind'] == 'loose'
          baseline_loose
        end
        flush_deltas(send: false)
        untrack(ctx) if ctx && !obj['meta_only']
        ensure_tracking(LOOSE_OID) if ctx == LOOSE_OID
        snapshot_fp(oid)
        if obj['kind'] == 'definition' && (d = live_def(did_of(oid)))
          d.instances.each { |i| entity_valid?(i) && (io = @eid_to_oid[i.entityID]) && snapshot_fp(io) }
        end
        refresh_overlay
      end
    end

    def verify_applied(obj)
      want = (obj['meta'] || {})['sighash']
      return unless want && !obj['meta_only'] && !obj['deleted']
      have = object_sighash(obj['oid'])
      return if have.nil?
      TeamHub.log_sync("VERIFY #{obj['oid']} r#{obj['rev']} contents #{have == want ? 'OK' : "MISMATCH #{have[0, 8]} != #{want[0, 8]}"}")
    end

    def stamp_rev_later(obj)
      when_idle do
        model_op('Team Hub') do
          if obj['kind'] == 'loose'
            @model.set_attribute(DICT, 'loose_rev', obj['rev'])
          elsif obj['kind'] == 'definition'
            d = live_def(did_of(obj['oid']))
            d.set_attribute(DICT, 'rev', obj['rev']) if d
          end
        end
      end
    end

    # While a Component is open for editing, SketchUp places every other copy
    # of it (and new copies) relative to the open one. Setting a position then
    # would land it somewhere else — wait until the edit context is closed.
    def placement_unsafe?(obj)
      path = @model.active_path
      return false if path.nil? || path.empty?
      path = path.select { |e| trackable?(e) }
      open_defs = path.map(&:definition).select { |d| entity_valid?(d) }
      ent = live_entity(obj['oid'])
      return true if ent && path.any? { |e| same_entity?(e, ent) }
      if ent && open_defs.any? { |d| same_entity?(d, ent.definition) }
        return true
      end
      if obj['kind'] == 'definition'
        return open_defs.any? { |d| d.get_attribute(DICT, 'did') == did_of(obj['oid']) }
      elsif obj['kind'] == 'component'
        defn = live_def((obj['meta'] || {})['def'])
        return open_defs.any? { |d| same_entity?(d, defn) }
      end
      false
    end

    def editing_now?(oid)
      return editing_loose_now? if oid == LOOSE_OID
      root = (@model.active_path || []).first
      trackable?(root) && (@eid_to_oid[root.entityID] == oid || ctx_of_root(root) == oid)
    rescue StandardError
      false
    end

    def apply_definition(obj, path)
      did = did_of(obj['oid'])
      old = live_def(did)
      copies = @model.definitions.select { |d| entity_valid?(d) && !d.group? && !d.image? && d.get_attribute(DICT, 'did') == did }
      if obj['deleted']
        @def_index.delete(did)
        copies.each do |d|
          d.instances.to_a.each do |inst|
            next unless entity_valid?(inst)
            inst.locked = false if inst.locked?
            top_level?(inst) ? erase_tracked(inst) : inst.erase!
          end
          @model.definitions.remove(d) if entity_valid?(d)
          raise "Could not remove definition #{did}" if entity_valid?(d)
        end
        return
      end
      meta = obj['meta'] || {}
      placements = old ? old.instances.select { |i| entity_valid?(i) }.map { |i| i.transformation } : []
      @objects.each_value do |o|
        m = o['meta'] || {}
        if o['kind'] == 'component' && !o['deleted'] && m['def'] == did && m['t'].is_a?(Array) && m['t'].size == 16
          placements << Geom::Transformation.new(m['t'])
        end
      end
      newdef = load_definition(path, meta, placements)
      @def_index[did] = newdef
      # A group/blob can embed another copy of a shared definition. Replace all
      # copies carrying this did, not just the one currently in @def_index.
      copies.each do |d|
        next unless entity_valid?(d) && !same_entity?(d, newdef)
        nested = nested_definitions(d)
        d.instances.to_a.each do |inst|
          next unless entity_valid?(inst)
          was = inst.locked?
          inst.locked = false if was
          inst.definition = newdef
          inst.locked = true if was
        end
        remove_definitions([d] + nested)
      end
      name = meta['name'].to_s
      begin
        newdef.name = name unless name.empty? || newdef.name == name
      rescue StandardError
        nil
      end
      newdef.description = meta['description'].to_s
      newdef.set_attribute(DICT, 'did', did)
      newdef.set_attribute(DICT, 'rev', obj['rev'])
      link_nested_definitions(newdef)
    end

    def link_nested_definitions(defn)
      nested_definitions(defn).each do |d|
        next unless entity_valid?(d) && !d.group? && !d.image?
        did = d.get_attribute(DICT, 'did')
        next unless did
        canonical = live_def(did)
        if canonical && !same_entity?(canonical, d)
          d.instances.to_a.each do |inst|
            next unless entity_valid?(inst)
            was = inst.locked?
            inst.locked = false if was
            inst.definition = canonical
            inst.locked = true if was
          end
          remove_definitions([d])
        elsif canonical.nil?
          @def_index[did] = d
        end
        server = @objects["d_#{did}"]
        if server && !server['deleted'] && local_rev(server) < server['rev'].to_i
          enqueue(server.merge('force' => true))
        end
      end
    end

    # A teammate only moved / renamed / repainted it: change it in place.
    def apply_group_meta(obj)
      ent = live_entity(obj['oid'])
      meta = obj['meta'] || {}
      t = meta['t']
      was = ent.locked?
      ent.locked = false if was
      ent.transformation = Geom::Transformation.new(t) if t.is_a?(Array) && t.size == 16
      finish_entity(ent, obj, ent)
    end

    def apply_group(obj, path)
      oid = obj['oid']
      old = live_entity(oid)
      if obj['deleted']
        erase_tracked(old)
        return
      end
      meta = obj['meta'] || {}
      placements = meta['t'].is_a?(Array) && meta['t'].size == 16 ? [Geom::Transformation.new(meta['t'])] : []
      defn = load_definition(path, meta, placements)
      link_nested_definitions(defn)
      grp = @model.entities.add_group
      raise "Could not explode group #{oid}" unless grp.entities.add_instance(defn, IDENTITY).explode
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
      raise "Missing definition for #{oid}" unless defn
      tr = meta['t'].is_a?(Array) && meta['t'].size == 16 ? Geom::Transformation.new(meta['t']) : IDENTITY
      if old.is_a?(Sketchup::ComponentInstance)
        old.locked = false
        old.definition = defn unless same_entity?(old.definition, defn)
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
      erase_tracked(old) if entity_valid?(old) && !same_entity?(old, ent)
      index_entity(ent)
      ent.locked = !mine?(oid)
    end

    def erase_tracked(ent)
      return unless entity_valid?(ent)
      oid = @eid_to_oid.delete(ent.entityID)
      @index.delete(oid) if oid && same_entity?(@index[oid], ent)
      defs = ent.is_a?(Sketchup::Group) ? [ent.definition] + nested_definitions(ent.definition) : []
      ent.locked = false if ent.locked?
      ent.erase!
      remove_definitions(defs)
    end

    def nested_definitions(defn, acc = [])
      return acc unless entity_valid?(defn)
      defn.entities.each do |e|
        next unless trackable?(e)
        d = e.definition
        next unless entity_valid?(d)
        next if acc.any? { |a| same_entity?(a, d) }
        acc << d
        nested_definitions(d, acc)
      end
      acc
    end

    # Removes definitions left unused by a replace, parents first.
    def remove_definitions(defs)
      defs = defs.select { |d| entity_valid?(d) }.uniq { |d| d.entityID }
      @def_index.delete_if { |_, d| !entity_valid?(d) }
      synced = @def_index.values.map { |d| d.entityID }
      loop do
        removed = false
        defs.each do |d|
          next unless entity_valid?(d) && d.instances.empty? && !synced.include?(d.entityID)
          begin
            @model.definitions.remove(d)
            removed = true unless entity_valid?(d)
          rescue StandardError => e
            TeamHub.log_sync("CLEANUP definition: #{e.message}")
          end
        end
        break unless removed
      end
    end

    def bbox_a(bb)
      bb.empty? ? nil : [bb.min.to_a, bb.max.to_a].map { |p| p.map { |v| v.to_f.round(6) } }
    end

    def load_definition(path, meta = {}, placements = [])
      tmp = File.join(@temp, "load_#{SecureRandom.hex(6)}.skp")
      FileUtils.cp(path, tmp)
      defn = @model.definitions.load(tmp)
      raise 'تعذر فتح ملف العنصر' unless defn
      align_definition(defn, meta, placements)
      defn
    ensure
      begin
        File.delete(tmp) if tmp && File.exist?(tmp)
      rescue StandardError
        nil
      end
    end

    # The sender told us where the contents sit (box min/max in x, y, z). If the
    # loaded copy sits anywhere else, move it back exactly; then double-check.
    def fresh_bounds(defn)
      defn.invalidate_bounds if defn.respond_to?(:invalidate_bounds)
    rescue StandardError
      nil
    end

    def align_definition(defn, meta, placements = [])
      expect_bb = meta['bb']
      unless meta['bb_space'] == 'local'
        TeamHub.log_sync("ALIGN SKIP #{defn.name}: unmarked/legacy bounds") if expect_bb
        return
      end
      return unless expect_bb.is_a?(Array) && expect_bb.size == 2
      return unless expect_bb.all? { |p| p.is_a?(Array) && p.size == 3 && p.all? { |v| v.is_a?(Numeric) && v.to_f.finite? } }
      fresh_bounds(defn)
      have = defn.bounds
      return if have.empty?
      want_min = Geom::Point3d.new(*expect_bb[0])
      delta = want_min - have.min
      if delta.length > 0.0001
        # The box is in the sender's local coordinates (local_bbox, 2.1+), so
        # any offset is the export's fault (SketchUp writes an open
        # definition in model space): move it back, as long as the size
        # matches — a different size means different contents, not an offset.
        want_size = Geom::Point3d.new(*expect_bb[1]) - want_min
        have_size = have.max - have.min
        if (want_size - have_size).length > 0.001
          TeamHub.log_sync("ALIGN SKIP #{defn.name}: size differs have #{have_size.to_a.inspect} want #{want_size.to_a.inspect}")
          return
        end
        defn.entities.transform_entities(Geom::Transformation.translation(delta), defn.entities.to_a)
        fresh_bounds(defn) # SketchUp keeps the old box until asked
        TeamHub.log_sync("ALIGN #{defn.name}: contents were off by #{delta.to_a.map { |v| v.to_f.round(3) }.inspect}, moved back")
      end
      got = bbox_a(defn.bounds)
      ok = got && got.flatten.zip(expect_bb.flatten).all? { |a, b| (a - b).abs < 0.001 }
      TeamHub.log_sync("VERIFY #{defn.name} box #{ok ? 'OK' : "MISMATCH have #{got.inspect} want #{expect_bb.inspect}"}")
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
          next unless entity_valid?(d) && server && !server['deleted'] && !mine?(d_oid) && server['updated_by'] == my_id
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
      entities = group_selected_loose(entities)
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
      oids = oids.select { |o| reserved_by_me?(o) }
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

    # Every few seconds: compare every object with how it looked last time, so
    # any change reaches the team even if SketchUp didn't report it.
    def request_sweep
      return if @sweep_pending || !@loaded || @stopped
      @sweep_pending = true
      when_idle do
        @sweep_pending = false
        @index.each_key { |o| @touched[o] = true }
        @model.entities.each do |e|
          next unless trackable?(e)
          @added << e unless same_entity?(live_entity(e.get_attribute(DICT, 'oid')), e)
        end
        # Definitions have no observer with deltas disabled. Check them during
        # sweeps too, including edits made through nested component instances.
        with_root_coordinates do
          @def_index.each do |did, d|
            begin
              next unless entity_valid?(d)
              oid = "d_#{did}"
              @def_dirty[did] = true if !@content_fp.key?(oid) || @content_fp[oid] != defn_fp(d)
            rescue StandardError => error
              @last_error = error.message
              TeamHub.log_error(error)
            end
          end
        end
        @loose_dirty = true
        scan
        pump_pushes
        heal_step
      end
    end

    # "Sync now": push my changes and pull the team's right away.
    def sync_now
      request_sweep
      poll
      run_jobs
      TeamHub.flash('دا يزامن هسه…')
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
      # Reservations (mine dashed, others solid) + what a teammate changed in the
      # last few seconds, so you see the other person working live.
      items = []
      @locks.each do |oid, uid|
        e = live_entity(oid)
        next unless e
        name = uid == my_id ? 'محجوز إلك' : "محجوز: #{(@users[uid] || {})['display_name'] || '؟'}"
        items << [e, color_of(uid), name, uid == my_id]
      end
      claims.each do |oid, uid|
        next if uid == my_id || @locks[oid]
        e = live_entity(oid)
        items << [e, color_of(uid), "✎ #{(@users[uid] || {})['display_name'] || '؟'} يعدّل", false] if e
      end
      now = Time.now
      @recent.delete_if { |_, (_, at)| now - at > 8 }
      @recent.each do |oid, (uid, _)|
        e = live_entity(oid)
        next unless e && !@locks[oid] && !claims[oid]
        items << [e, color_of(uid), "✎ #{(@users[uid] || {})['display_name'] || '؟'}", false]
      end
      changed = items.map { |e, *_| e.entityID } != (@overlay_items || []).map { |e, *_| e.valid? ? e.entityID : 0 }
      @overlay_items = items
      return unless changed || !items.empty?
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
        next unless entity_valid?(e)
        {
          oid: oid,
          name: display_name(e),
          kind: e.is_a?(Sketchup::Group) ? 'group' : 'component',
          layer: (e.layer.display_name rescue ''),
          lock: @locks[oid],
          mine: reserved_by_me?(oid),
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
        ping: @ping_ms,
        transport: ws_open? ? 'websocket' : 'longpoll',
        editing_by_others: claims.count { |_, uid| uid != my_id },
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
    def onElementModified(_entities, entity)
      @s.guard { @s.on_modified(entity) }
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
