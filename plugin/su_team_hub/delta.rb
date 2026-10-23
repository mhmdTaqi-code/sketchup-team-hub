# Live geometry operations ("game-server" sync).
#
# Instead of re-sending a whole Group when one face changes, every operation
# is sent as a small delta: which faces/edges/instances were removed (by
# signature) and which were added (as plain geometry). Everyone applies the
# same deltas, so two people can work inside the same Group/Component at the
# same moment and both edits survive — no copies.
#
# A "context" is where the geometry lives:
#   loose_top        the model root (loose edges/faces)
#   o<hex>           a top-level Group (its own definition)
#   d_<did>          a Component definition (shared by all its instances)
#
# All coordinates in deltas are in the context's LOCAL space. SketchUp reports
# and accepts coordinates in model space for a context that is open for
# editing, so we convert both ways (this is what made shapes land in different
# places before).

require 'set'
require 'digest'

module TeamHub
  class Session
    # OFF since 2.0: replaying single operations let the two models drift apart
    # (SketchUp splits/merges geometry differently on each side) → deleted and
    # duplicated shapes. Whole objects travel instead, one editor at a time.
    DELTA_ENABLED = false
    DELTA_LIVE_SECS = 90     # after a delta, checkpoints don't replace that context
    CHECKPOINT_EVERY = 30    # while editing live, a full copy goes up at most this often

    class DeltaObs < Sketchup::EntitiesObserver
      def initialize(session, ctx)
        @s = session
        @ctx = ctx
      end

      def onElementAdded(_entities, e)
        @s.delta_record(@ctx, :add, e)
      end

      def onElementModified(_entities, e)
        @s.delta_record(@ctx, :mod, e)
      end

      def onElementRemoved(_entities, eid)
        @s.delta_record(@ctx, :rm, eid)
      end
    end

    # ------------------------------------------------------------ contexts

    def ctx_entities(ctx)
      if ctx == LOOSE_OID
        @model.entities
      elsif ctx.start_with?('d_')
        d = live_def(did_of(ctx))
        d && d.entities
      else
        e = live_entity(ctx)
        e.is_a?(Sketchup::Group) ? e.definition.entities : nil
      end
    end

    # Which context does the user's open edit path belong to?
    def ctx_of_root(root)
      return nil unless trackable?(root)
      if root.is_a?(Sketchup::Group)
        @eid_to_oid[root.entityID]
      elsif root.is_a?(Sketchup::ComponentInstance)
        did = root.definition.get_attribute(DICT, 'did')
        did ? "d_#{did}" : nil
      end
    end

    # Local → model transformation of a context while it is open for editing
    # (nil when it isn't open, i.e. coordinates are already local).
    def ctx_open_tr(ctx)
      return nil if ctx == LOOSE_OID
      path = @model.active_path
      return nil if path.nil? || path.empty?
      root = path.first
      return nil unless ctx_of_root(root) == ctx
      oid = @eid_to_oid[root.entityID]
      t = oid && @last_t && @last_t[oid]
      t ? Geom::Transformation.new(t) : (path.size == 1 ? @model.edit_transform : root.transformation)
    end

    def to_local(pt, tr)
      tr ? pt.transform(tr.inverse) : pt
    end

    def to_api(pt, tr)
      tr ? pt.transform(tr) : pt
    end

    # ------------------------------------------------------------ serialize + signatures

    def r3(v)
      (v.to_f * 1000).round / 1000.0
    end

    def pt_a(p)
      [r3(p.x), r3(p.y), r3(p.z)]
    end

    def ser(e, tr)
      if e.is_a?(Sketchup::Edge)
        { 't' => 'e', 'p' => [pt_a(to_local(e.start.position, tr)), pt_a(to_local(e.end.position, tr))],
          's' => e.soft?, 'm' => e.smooth?, 'h' => e.hidden?, 'l' => e.layer.name }
      elsif e.is_a?(Sketchup::Face)
        outer = e.outer_loop.vertices.map { |v| pt_a(to_local(v.position, tr)) }
        inner = e.loops.reject(&:outer?).map { |lp| lp.vertices.map { |v| pt_a(to_local(v.position, tr)) } }
        { 't' => 'f', 'o' => outer, 'i' => inner, 'm' => mat_a(e.material), 'b' => mat_a(e.back_material),
          'l' => e.layer.name }
      elsif e.is_a?(Sketchup::ComponentInstance)
        t = e.transformation
        t = tr.inverse * t if tr
        { 't' => 'i', 'd' => e.definition.name, 'tr' => t.to_a.map { |v| r3(v) }, 'l' => e.layer.name,
          'n' => e.name }
      end
    end

    def mat_a(m)
      m ? [m.name, m.color.to_a] : nil
    end

    def sig_of(h)
      case h['t']
      when 'e' then "e#{h['p'].map { |p| p.join(',') }.sort.join(';')}"
      when 'f'
        "f#{h['o'].map { |p| p.join(',') }.sort.join(';')}|#{h['i'].flatten(1).map { |p| p.join(',') }.sort.join(';')}" \
          "|#{h['m'] && h['m'][0]}|#{h['b'] && h['b'][0]}"
      when 'i' then "i#{h['d']}|#{h['tr'].join(',')}"
      end
    end

    def delta_supported?(e)
      e.is_a?(Sketchup::Edge) || e.is_a?(Sketchup::Face) || e.is_a?(Sketchup::ComponentInstance)
    end

    # ------------------------------------------------------------ tracking

    def dtrack
      @dtrack ||= {} # ctx => { sig: {eid=>sig}, ents: {eid=>entity}, obs:, ents_coll:, at: }
    end

    def dchanges
      @dchanges ||= {} # ctx => { add: {eid=>e}, mod: {eid=>e}, rm: Set }
    end

    def delta_live
      @delta_live ||= {} # ctx => Time of last delta in/out
    end

    def delta_live?(ctx)
      return false unless DELTA_ENABLED
      t = delta_live[ctx]
      t && Time.now - t < DELTA_LIVE_SECS
    end

    def ctx_owner(ctx)
      return nil if ctx == LOOSE_OID
      return live_def(did_of(ctx)) if ctx.start_with?('d_')
      e = live_entity(ctx)
      e.is_a?(Sketchup::Group) ? e.definition : nil
    end

    def tracking_valid?(t)
      t && (t[:owner].nil? || same_entity?(t[:owner], ctx_owner(t[:ctx])))
    end

    def ensure_tracking(ctx)
      return nil unless DELTA_ENABLED
      return dtrack[ctx] if tracking_valid?(dtrack[ctx])
      untrack(ctx)
      coll = ctx_entities(ctx)
      return nil unless coll
      tr = ctx_open_tr(ctx)
      sigs = {}
      ents = {}
      coll.each do |e|
        next unless delta_supported?(e)
        next if ctx == LOOSE_OID && e.is_a?(Sketchup::ComponentInstance) # top-level objects sync on their own
        h = ser(e, tr)
        next unless h
        sigs[e.entityID] = sig_of(h)
        ents[e.entityID] = e
      end
      obs = DeltaObs.new(self, ctx)
      coll.add_observer(obs)
      dtrack[ctx] = { ctx: ctx, sig: sigs, ents: ents, obs: obs, coll: coll, owner: ctx_owner(ctx), at: Time.now }
    end

    # Stop watching a context (before its geometry is replaced wholesale, so the
    # replacement is never mistaken for the user deleting everything).
    def untrack(ctx)
      t = dtrack.delete(ctx)
      dchanges.delete(ctx)
      return unless t
      begin
        t[:coll].remove_observer(t[:obs]) if t[:owner].nil? || t[:owner].valid?
      rescue StandardError
        nil
      end
    end

    def untrack_all
      dtrack.keys.each { |c| untrack(c) }
    end

    # Called by DeltaObs for every change, ours or SketchUp's.
    def delta_record(ctx, kind, e)
      ch = (dchanges[ctx] ||= { add: {}, mod: {}, rm: Set.new })
      case kind
      when :rm then ch[:rm] << e
      when :add then ch[:add][e.entityID] = e if e.valid?
      when :mod then ch[:mod][e.entityID] = e if e.valid?
      end
    end

    # Turn recorded changes into a delta (and keep the signature maps right).
    # send=false after applying a teammate's delta: only update the maps.
    def flush_deltas(send:)
      unless DELTA_ENABLED
        @dchanges = {}
        return
      end
      return if dchanges.empty?
      list = dchanges
      @dchanges = {}
      list.each do |ctx, ch|
        t = dtrack[ctx]
        next unless t
        tr = ctx_open_tr(ctx)
        rm = []
        add = []
        fallback = false
        ch[:rm].each do |eid|
          s = t[:sig].delete(eid)
          t[:ents].delete(eid)
          rm << s if s
        end
        (ch[:mod].merge(ch[:add])).each do |eid, e|
          next unless e.valid?
          if ctx == LOOSE_OID && (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance))
            next
          end
          unless delta_supported?(e)
            fallback = true unless ctx == LOOSE_OID && e.is_a?(Sketchup::Group)
            next
          end
          if e.is_a?(Sketchup::Group)
            fallback = true
            next
          end
          h = ser(e, tr)
          next unless h
          s = sig_of(h)
          old = t[:sig][eid]
          next if old == s
          rm << old if old
          t[:sig][eid] = s
          t[:ents][eid] = e
          add << h
        end
        next unless send && !viewer?
        # Removed then re-added identical geometry → nothing to send.
        added = add.map { |h| sig_of(h) }
        common = rm & added
        rm -= common
        add.reject! { |h| common.include?(sig_of(h)) }
        mark_checkpoint_needed(ctx) if fallback
        next if rm.empty? && add.empty?
        delta_live[ctx] = Time.now
        queue_delta(ctx, rm, add)
      end
    end

    def mark_checkpoint_needed(ctx)
      if ctx == LOOSE_OID
        @loose_dirty = true
      elsif ctx.start_with?('d_')
        @def_dirty[did_of(ctx)] = true
      else
        @content_dirty[ctx] = true
      end
    end

    # ------------------------------------------------------------ sending (ordered)

    def queue_delta(ctx, rm, add)
      (@delta_out ||= []) << { 'ctx' => ctx, 'rm' => rm, 'add' => add }
      pump_deltas
    end

    # pump_deltas: WebSocket first, HTTP fallback — see live_ws.rb

    # ------------------------------------------------------------ receiving

    def enqueue_delta(payload, user)
      return unless DELTA_ENABLED
      @jobs << { 'oid' => "delta:#{SecureRandom.hex(4)}", 'kind' => 'delta', 'delta' => payload, 'user' => user }
      run_jobs
    end

    def apply_delta(job)
      d = job['delta']
      ctx = d['ctx']
      t = ensure_tracking(ctx)
      return unless t # we don't have that object (yet): its checkpoint brings it
      flush_deltas(send: true) # send my own pending changes first
      tr = ctx_open_tr(ctx)
      coll = t[:coll]
      by_sig = {}
      t[:sig].each { |eid, s| (by_sig[s] ||= []) << eid }
      model_op('Team Hub: تعديل الفريق') do
        doomed = d['rm'].filter_map do |s|
          eid = (by_sig[s] || []).pop
          e = eid && t[:ents][eid]
          e if e && e.valid?
        end
        faces, rest = doomed.partition { |e| e.is_a?(Sketchup::Face) }
        coll.erase_entities(faces) unless faces.empty?
        rest.select!(&:valid?)
        coll.erase_entities(rest) unless rest.empty?
        d['add'].sort_by { |h| { 'e' => 0, 'f' => 1, 'i' => 2 }[h['t']] || 3 }.each { |h| add_from(coll, h, tr) }
      end
      flush_deltas(send: false)
      delta_live[ctx] = Time.now
      uid = job['user'] && job['user']['id']
      if uid && ctx != LOOSE_OID
        target = ctx.start_with?('d_') ? nil : ctx
        @recent[target] = [uid, Time.now] if target
      end
      @loose_base = loose_fp if ctx == LOOSE_OID
      snapshot_fp(ctx) unless ctx == LOOSE_OID
      refresh_overlay
    end

    def add_from(coll, h, tr)
      layer = h['l'] && !h['l'].empty? ? (@model.layers[h['l']] || @model.layers.add(h['l'])) : nil
      case h['t']
      when 'e'
        e = coll.add_line(*h['p'].map { |p| to_api(Geom::Point3d.new(*p), tr) })
        return unless e
        e.soft = h['s'] ? true : false
        e.smooth = h['m'] ? true : false
        e.hidden = h['h'] ? true : false
        e.layer = layer if layer
      when 'f'
        f = coll.add_face(h['o'].map { |p| to_api(Geom::Point3d.new(*p), tr) })
        return unless f
        (h['i'] || []).each do |loop_pts|
          hole = coll.add_face(loop_pts.map { |p| to_api(Geom::Point3d.new(*p), tr) })
          hole.erase! if hole && hole.valid?
        rescue ArgumentError
          nil
        end
        f.material = material_for(h['m']) if h['m']
        f.back_material = material_for(h['b']) if h['b']
        f.layer = layer if layer
      when 'i'
        defn = @model.definitions[h['d']]
        return unless defn && !defn.group?
        local = Geom::Transformation.new(h['tr'])
        inst = coll.add_instance(defn, tr ? tr * local : local)
        inst.layer = layer if layer
        inst.name = h['n'].to_s if h['n']
      end
    rescue ArgumentError, TypeError
      nil # degenerate geometry (e.g. a face whose points became collinear)
    end

    def material_for(m)
      name, color = m
      mat = @model.materials[name]
      unless mat
        mat = @model.materials.add(name)
        mat.color = Sketchup::Color.new(*color) if color
      end
      mat
    end

    # Same contents? (to skip replacing a context that deltas already updated)
    def ctx_sighash(ctx)
      t = ensure_tracking(ctx)
      t ? Digest::SHA1.hexdigest(t[:sig].values.sort.join("\n")) : nil
    end

    def ctx_for_object(obj)
      case obj['kind']
      when 'loose' then LOOSE_OID
      when 'definition' then obj['oid']
      when 'group' then obj['oid']
      end
    end
  end
end
