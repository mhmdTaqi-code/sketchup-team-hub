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
      @model.entities.select { |e| loose?(e) }
    end

    # Cheap fingerprint: counts + total area/length (changes with any edit).
    def loose_fp
      faces = edges = other = 0
      area = len = 0.0
      @model.entities.each do |e|
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
      @loose_base = loose_fp
    end

    def scan_loose
      return unless @loose_dirty
      @loose_dirty = false
      return if viewer? || reserved_by_other?(LOOSE_OID)
      fp = loose_fp
      return if fp == @loose_base
      request_push(LOOSE_OID, true)
    end

    def push_loose
      list = loose_entities
      fp = loose_fp
      body = { 'kind' => 'loose', 'name' => 'خطوط وسطوح سائبة', 'layer' => '', 'meta' => { 'empty' => list.empty? } }
      body['data'] = list.empty? ? ['EMPTY'].pack('m0') : export_loose
      @pushing[LOOSE_OID] = true
      notify
      @client.request(:post, "/api/projects/#{pid}/objects/#{LOOSE_OID}", body, timeout: 600) do |st, data|
        @pushing.delete(LOOSE_OID)
        next if @stopped
        if st == 200 && data
          @objects[LOOSE_OID] = data['object']
          @loose_base = fp
          rev = data['object']['rev']
          when_idle { model_op('Team Hub') { @model.set_attribute(DICT, 'loose_rev', rev) } }
        elsif st.zero?
          @status = :offline
          @push_wanted[LOOSE_OID] = true
        elsif st == 423
          TeamHub.flash('الخطوط السائبة محجوزة من عضو ثاني')
        end
        when_idle { pump_pushes }
        notify
      end
    end

    # Group a copy of the loose geometry just long enough to save it, then undo.
    def export_loose
      out = File.join(@temp, "loose_#{SecureRandom.hex(6)}.skp")
      @suspended += 1
      @model.start_operation('Team Hub export', true)
      begin
        g = @model.entities.add_group(loose_entities)
        ok = TeamHub.save_definition(g.definition, out)
      ensure
        @model.abort_operation
        @suspended -= 1
      end
      raise 'تعذر حفظ الخطوط السائبة' unless ok && File.exist?(out)
      [File.binread(out)].pack('m0')
    ensure
      File.delete(out) if out && File.exist?(out)
    end

    def apply_loose(obj, path)
      old = loose_entities
      old.each { |e| e.locked = false if e.respond_to?(:locked=) && e.respond_to?(:locked?) && e.locked? }
      @model.entities.erase_entities(old) unless old.empty?
      unless (obj['meta'] || {})['empty'] || path.nil?
        defn = load_definition(path)
        @model.entities.add_instance(defn, IDENTITY).explode
        remove_definitions([defn])
      end
      @model.set_attribute(DICT, 'loose_rev', obj['rev'])
      @loose_base = loose_fp
    end

    def editing_loose_now?
      (@model.active_path || []).empty? && (@loose_dirty || @pushing[LOOSE_OID] || @push_wanted.key?(LOOSE_OID))
    end

    # Reserving needs a Group: turn selected loose geometry into one first.
    def group_selected_loose(entities)
      loose = entities.select { |e| loose?(e) && top_level?(e) }
      return entities if loose.empty?
      msg = "حددت #{loose.size} خط/سطح سايب. حتى تحجزهن لازم يصيرن Group.\nأسويهن Group وأحجزه إلك؟"
      return entities - loose unless UI.messagebox(msg, MB_YESNO) == IDYES
      @model.start_operation('Team Hub: Group للحجز', true)
      g = @model.entities.add_group(loose)
      @model.commit_operation
      @added << g
      process_added
      @model.selection.add(g)
      (entities - loose) + [g]
    end
  end
end
