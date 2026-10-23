# Loose geometry: edges and faces drawn straight in the model (not inside a
# Group/Component) sync too. All of it travels as one piece ("loose_top"):
# exported by temporarily grouping it (operation aborted right after), and
# applied on the other side by replacing the receiver's loose geometry.

require 'securerandom'

module TeamHub
  LOOSE_OID = 'loose_top'.freeze

  class Session
    LOOSE_TYPES = [Sketchup::Face, Sketchup::Edge, Sketchup::ConstructionLine, Sketchup::ConstructionPoint].freeze

    def loose?(e)
      LOOSE_TYPES.any? { |t| e.is_a?(t) }
    end

    def loose_entities
      @model.entities.select { |e| entity_valid?(e) && loose?(e) }
    end

    # Cheap fingerprint: counts + total area/length (changes with any edit).
    def loose_fp
      faces = edges = other = 0
      area = len = 0.0
      @model.entities.each do |e|
        next unless entity_valid?(e)
        if e.is_a?(Sketchup::Face)
          faces += 1
          area += e.area
        elsif e.is_a?(Sketchup::Edge)
          edges += 1
          len += e.length.to_f
        elsif loose?(e)
          other += 1
        end
      end
      [faces, edges, other, area.round(3), len.round(4)]
    end

    def loose_rev
      @model.get_attribute(DICT, 'loose_rev', 0).to_i
    end

    def mark_loose_dirty
      @loose_dirty = true
    end

    def baseline_loose
      @loose_base = loose_content_fp
      remember_loose_ids
    end

    def loose_content_fp
      loose_fp # counts + total area/length: cheap enough for every sweep
    end

    # Loose geometry travels live as deltas; this full copy is only for people
    # joining later. It is made in the model root context only (inside a Group
    # SketchUp would move it to edit-space coordinates).
    def scan_loose
      return unless @loose_dirty
      return if viewer? || reserved_by_other?(LOOSE_OID)
      return unless (@model.active_path || []).empty?
      return if delta_live?(LOOSE_OID) && Time.now - (@loose_cp_at || Time.at(0)) < CHECKPOINT_EVERY
      @loose_dirty = false
      fp = loose_content_fp
      return if fp == @loose_base
      @loose_cp_at = Time.now
      request_push(LOOSE_OID, true)
    end

    def push_loose
      list = loose_entities
      fp = loose_content_fp
      @loose_export_t = @loose_export_bb = nil
      body = { 'kind' => 'loose', 'name' => 'خطوط وسطوح سائبة', 'layer' => '', 'meta' => { 'empty' => list.empty? } }
      body['base_rev'] = loose_rev if @objects[LOOSE_OID] && !@objects[LOOSE_OID]['deleted']
      body['data'] = list.empty? ? ['EMPTY'].pack('m0') : export_loose
      body['meta']['lt'] = @loose_export_t if @loose_export_t
      body['meta']['bb'] = @loose_export_bb if @loose_export_bb
      body['meta']['bb_space'] = 'local'
      sh = object_sighash(LOOSE_OID)
      body['meta']['sighash'] = sh if sh
      sent_ids = {}
      loose_entities.each { |e| sent_ids[e.entityID] = true }
      TeamHub.log_sync("PUSH loose (#{list.size} entities) base r#{body['base_rev'].inspect}")
      @pushing[LOOSE_OID] = true
      notify
      @client.request(:post, "/api/projects/#{pid}/objects/#{LOOSE_OID}", body, timeout: 600) do |st, data|
        @pushing.delete(LOOSE_OID)
        next if @stopped
        begin
          if st == 200 && data
            obj = data['object']
            latest = @objects[LOOSE_OID]
            @objects[LOOSE_OID] = obj unless latest && latest['rev'].to_i > obj['rev'].to_i
            @loose_base = fp
            @loose_ids = sent_ids
            rev = data['object']['rev']
            when_idle { model_op('Team Hub') { @model.set_attribute(DICT, 'loose_rev', rev) if loose_rev < rev.to_i } }
          elsif st.zero?
            @status = :offline
            @push_wanted[LOOSE_OID] = true
          elsif st == 409 || (st == 423 && data && data['error'] == 'being_edited')
            when_idle { lost_race(LOOSE_OID, data) }
          elsif st == 423
            TeamHub.flash('الخطوط السائبة محجوزة من عضو ثاني')
            enqueue(@objects[LOOSE_OID].merge('force' => true, '_refresh' => true)) if @objects[LOOSE_OID]
          else
            @push_wanted[LOOSE_OID] = true
            (@push_retry_at ||= {})[LOOSE_OID] = Time.now + 10
          end
        rescue StandardError => e
          @push_wanted[LOOSE_OID] = true
          (@push_retry_at ||= {})[LOOSE_OID] = Time.now + 5
          @last_error = e.message
          TeamHub.log_error(e)
        ensure
          when_idle { pump_pushes }
          notify
        end
      end
    end

    # Group a copy of the loose geometry just long enough to save it, then undo.
    def export_loose
      raise 'inside a Group: loose export waits for the model root' unless (@model.active_path || []).empty?
      out = File.join(@temp, "loose_#{SecureRandom.hex(6)}.skp")
      untrack(LOOSE_OID) # the temporary group must not become deltas
      ok = false
      suspend_sync do
        started = false
        @operation_depth = (@operation_depth || 0) + 1
        begin
          started = @model.start_operation('Team Hub export', true)
          raise 'Team Hub could not start loose export' unless started
          g = @model.entities.add_group(loose_entities)
          # SketchUp puts a new group's origin at the corner of its contents:
          # remember that offset (and the contents' box) so the other side can
          # place the lines at exactly the same x, y, z.
          @loose_export_t = g.transformation.to_a
          @loose_export_bb = bbox_a(g.definition.bounds)
          ok = TeamHub.save_definition(g.definition, out)
        ensure
          begin
            if started
              raise 'Team Hub could not abort loose export' unless @model.abort_operation
            end
          ensure
            @operation_depth -= 1
          end
        end
      end
      raise 'تعذر حفظ الخطوط السائبة' unless ok && File.exist?(out)
      [File.binread(out)].pack('m0')
    ensure
      begin
        File.delete(out) if out && File.exist?(out)
      ensure
        ensure_tracking(LOOSE_OID)
      end
    end

    def apply_loose(obj, path)
      old = loose_entities
      # Lines I drew that haven't reached the server yet must never be wiped
      # by someone else's version: they become my own Group first.
      mine = @loose_ids ? old.reject { |e| @loose_ids[e.entityID] } : []
      if !mine.empty? && obj['updated_by'] != my_id
        g = @model.entities.add_group(mine)
        g.name = "رسمة #{@me['display_name']}"
        @added << g
        TeamHub.log_sync("KEEP #{mine.size} unsent loose entities as my group before applying loose r#{obj['rev']}")
        UI.start_timer(0, false) { guard { process_added } }
        old = loose_entities
      end
      old.each { |e| e.locked = false if e.respond_to?(:locked=) && e.respond_to?(:locked?) && e.locked? }
      @model.entities.erase_entities(old) unless old.empty?
      meta = obj['meta'] || {}
      unless meta['empty'] || path.nil?
        place = meta['lt'].is_a?(Array) && meta['lt'].size == 16 ? Geom::Transformation.new(meta['lt']) : IDENTITY
        defn = load_definition(path, meta, [place])
        raise 'Could not explode loose geometry' unless @model.entities.add_instance(defn, place).explode
        remove_definitions([defn])
      end
      @model.set_attribute(DICT, 'loose_rev', obj['rev'])
    end

    def editing_loose_now?
      return false unless mine?(LOOSE_OID) && (@model.active_path || []).empty?
      @pushing[LOOSE_OID] || @push_wanted.key?(LOOSE_OID) || (@loose_dirty && loose_content_fp != @loose_base)
    end

    # Reserving needs a Group: turn selected loose geometry into one first.
    def group_selected_loose(entities)
      entities = entities.select { |e| entity_valid?(e) }
      loose = entities.select { |e| loose?(e) && top_level?(e) }
      return entities if loose.empty?
      loose_ids = loose.map { |e| e.entityID }
      rest = entities.reject { |e| loose_ids.include?(e.entityID) }
      msg = "حددت #{loose.size} خط/سطح سايب. حتى تحجزهن لازم يصيرن Group.\nأسويهن Group وأحجزه إلك؟"
      return rest unless UI.messagebox(msg, MB_YESNO) == IDYES
      g = nil
      model_op('Team Hub: Group للحجز') { g = @model.entities.add_group(loose) }
      mark_loose_dirty
      @added << g
      process_added
      @model.selection.add(g)
      rest.select { |e| entity_valid?(e) } + [g]
    end
  end
end
