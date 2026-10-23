# Reliability layer (v2):
#   * one editor at a time per object — what I select or open is claimed for
#     me right away and locked on everyone else's screen until I'm done;
#   * a content fingerprint ("sighash") travels with every upload; receivers
#     keep comparing their copy with the server's and re-download anything
#     that drifted (contents or position) — self-healing;
#   * a sync log (and "send log" button) so problems can be diagnosed.

require 'digest'
require 'fileutils'

module TeamHub
  LOG_PATH = File.join(ENV['APPDATA'] || Dir.home, 'TeamHub', 'sketchup.log')

  def self.log_sync(msg)
    FileUtils.mkdir_p(File.dirname(LOG_PATH))
    if File.exist?(LOG_PATH) && File.size(LOG_PATH) > 4_000_000
      File.rename(LOG_PATH, "#{LOG_PATH}.old") rescue nil
    end
    File.open(LOG_PATH, 'a:UTF-8') { |f| f.puts("#{Time.now.strftime('%Y-%m-%d %H:%M:%S.%L')} #{msg}") }
  rescue StandardError
    nil
  end

  def self.send_log
    text = File.exist?(LOG_PATH) ? File.read(LOG_PATH, encoding: 'UTF-8') : ''
    text = text[-2_000_000..] if text.size > 2_000_000
    client.request(:post, '/api/logs', { 'text' => "#{su_version_label} plugin #{PLUGIN_VERSION}\n#{text}" }, timeout: 60) do |st, data|
      flash(st == 200 ? "انرسل السجل (#{data && data['file']}). شكراً!" : 'ما انرسل السجل')
    end
  end

  class Session
    HEAL_PER_SWEEP = 12

    # ------------------------------------------------------------ fingerprints

    # Order-independent signature of an object's own geometry, in its local
    # coordinates. Only meaningful while no edit context is open.
    def sighash_of_entities(ents, seen = {}, detailed = false)
      sigs = []
      ents.each do |e|
        next unless entity_valid?(e)
        unless detailed
          # Keep the wire signature compatible with 2.0 peers and stored blobs.
          case e
          when Sketchup::Edge
            sigs << "e#{[e.start.position, e.end.position].map { |p| pt_a(p).join(',') }.sort.join(';')}#{e.soft? ? 's' : ''}"
          when Sketchup::Face
            sigs << "f#{e.outer_loop.vertices.map { |v| pt_a(v.position).join(',') }.sort.join(';')}" \
                    "|#{e.loops.size}|#{e.material&.name}|#{e.back_material&.name}"
          when Sketchup::Group, Sketchup::ComponentInstance
            b = e.definition.bounds
            sigs << "i#{e.transformation.to_a.map { |v| r3(v) }.join(',')}|#{e.definition.entities.length}" \
                    "|#{pt_a(b.min).join(',')}|#{pt_a(b.max).join(',')}"
          end
          next
        end
        appearance = "|#{e.layer.name}|#{e.hidden?}|#{e.material&.name}"
        case e
        when Sketchup::Edge
          sigs << "e#{[e.start.position, e.end.position].map { |p| pt_a(p).join(',') }.sort.join(';')}#{e.soft? ? 's' : ''}|#{e.smooth?}#{appearance}"
        when Sketchup::Face
          loops = e.loops.map { |lp| lp.vertices.map { |v| pt_a(v.position).join(',') }.sort.join(';') }.sort
          sigs << "f#{loops.join('/')}|#{e.back_material&.name}#{appearance}"
        when Sketchup::Group, Sketchup::ComponentInstance
          b = e.definition.bounds
          id = e.definition.entityID
          nested = ''
          unless seen[id]
            seen[id] = true
            nested = sighash_of_entities(e.definition.entities, seen, true)
            seen.delete(id)
          end
          sigs << "i#{e.transformation.to_a.map { |v| r3(v) }.join(',')}|#{e.definition.entities.length}" \
                  "|#{pt_a(b.min).join(',')}|#{pt_a(b.max).join(',')}|#{nested}|#{e.name}#{appearance}"
        else
          b = e.bounds
          sigs << "#{e.typename}|#{bbox_a(b).inspect}#{appearance}"
        end
      end
      Digest::SHA1.hexdigest(sigs.sort.join("\n"))
    end

    def object_sighash(oid)
      return nil unless (@model.active_path || []).empty?
      if oid == LOOSE_OID
        sighash_of_entities(@model.entities.select { |e| loose?(e) })
      elsif oid.start_with?('d_')
        d = live_def(did_of(oid))
        d && sighash_of_entities(d.entities)
      else
        e = live_entity(oid)
        e.is_a?(Sketchup::Group) ? sighash_of_entities(e.definition.entities) : nil
      end
    end

    def same_t?(a, b)
      a && b && a.size == 16 && b.size == 16 && a.zip(b).all? { |x, y| (x.to_f - y.to_f).abs < 0.01 }
    end

    # ------------------------------------------------------------ self-healing

    # A few objects per sweep: is my copy what the server says it is?
    def heal_step
      return if @stopped || !@loaded || !(@model.active_path || []).empty? || busy?
      @heal_keys = @objects.keys if @heal_keys.nil? || @heal_keys.empty?
      @heal_keys.shift(HEAL_PER_SWEEP).each do |oid|
        o = @objects[oid]
        next if o.nil?
        next if @pushing[oid] || @push_wanted.key?(oid) || @touched[oid] || @content_dirty[oid]
        next if @delete_wanted[oid] || (@deleting || {})[oid]
        next if @running_job && @running_job['oid'] == oid
        next if @jobs.any? { |j| j['oid'] == oid }
        if o['deleted']
          if local_exists?(o) && (oid != LOOSE_OID || !loose_entities.empty? || loose_rev < o['rev'].to_i)
            TeamHub.log_sync("HEAL deleted #{oid} r#{o['rev']}")
            enqueue(o.merge('force' => true))
          end
          next
        end
        unless local_exists?(o)
          # A definition nobody places any more (its last copy was deleted)
          # is not missing; the components that use it bring it when needed.
          if o['kind'] == 'definition'
            did = did_of(oid)
            used = @objects.each_value.any? { |c| c['kind'] == 'component' && !c['deleted'] && (c['meta'] || {})['def'] == did }
            next unless used
          end
          TeamHub.log_sync("HEAL missing #{oid} r#{o['rev']}")
          enqueue(o.merge('force' => true))
          next
        end
        next if claims[oid] == my_id || (o['kind'] == 'definition' && @def_dirty[did_of(oid)])
        if local_rev(o) != o['rev'].to_i
          TeamHub.log_sync("HEAL revision #{oid} local r#{local_rev(o)} server r#{o['rev']}")
          enqueue(o.merge('force' => true))
          next
        end
        meta = o['meta'] || {}
        if %w[group component].include?(o['kind']) && (ent = live_entity(oid)) && meta['t'].is_a?(Array)
          unless same_t?(ent.transformation.to_a, meta['t'])
            TeamHub.log_sync("HEAL position #{oid} #{display_name(ent)}")
            enqueue(o.merge('force' => true, 'meta_only' => o['kind'] == 'group'))
            next
          end
        end
        want = meta['sighash']
        next unless want
        have = object_sighash(oid)
        next if have.nil? || have == want
        last = (@heal_failed ||= {})[oid]
        next if last && last[0] == o['rev'] && Time.now - last[1] < 60
        @heal_failed[oid] = [o['rev'], Time.now]
        TeamHub.log_sync("HEAL contents #{oid} (#{o['kind']} r#{o['rev']}) local #{have[0, 8]} != server #{want[0, 8]}")
        enqueue(o.merge('force' => true))
      end
    end

    # ------------------------------------------------------------ claim on selection

    class SelObs < Sketchup::SelectionObserver
      def initialize(session)
        @s = session
      end

      def onSelectionBulkChange(_sel)
        @s.guard { @s.on_selection }
      end

      def onSelectionAdded(_sel, _e)
        @s.guard { @s.on_selection }
      end
    end

    def on_selection
      return if @suspended.positive? || !@loaded || viewer?
      UI.stop_timer(@sel_timer) if @sel_timer
      @sel_timer = UI.start_timer(0.08, false) do
        @sel_timer = nil
        sel = @model.selection.to_a
        next if sel.size > 30
        sel.each do |e|
          next unless top_level?(e)
          oid = @eid_to_oid[e.entityID]
          note_activity(oid) if oid && mine?(oid)
        end
      end
    end

    def attach_selection_observer
      @sel_obs = SelObs.new(self)
      @model.selection.add_observer(@sel_obs)
    end

    def detach_selection_observer
      @model.selection.remove_observer(@sel_obs) if @sel_obs
    rescue StandardError
      nil
    end

    # ------------------------------------------------------------ someone else got there first

    def lost_race(oid, data)
      who = (data && data['user'] && data['user']['display_name']) || 'عضو ثاني'
      @new_local.delete(oid)
      @push_wanted.delete(oid)
      @touched.delete(oid)
      @content_dirty.delete(oid)
      @def_dirty.delete(did_of(oid)) if oid.start_with?('d_')
      my_claims.delete(oid)
      claims[oid] = data['user']['id'] if data && data['user']
      server = @objects[oid]
      TeamHub.log_sync("LOST #{oid} to #{who} (#{data && data['error']}) → taking theirs")
      if server.nil? && data && data['error'] == 'being_edited'
        # A claim can exist before the object's first upload. There is no team
        # version to download yet, so retain this addition until the claim ends.
        @new_local[oid] = true unless oid == LOOSE_OID || oid.start_with?('d_')
        @push_wanted[oid] = true
        (@push_retry_at ||= {})[oid] = Time.now + 10
        return
      end
      if oid == LOOSE_OID
        keep_my_loose(who) # my new lines become my own Group, nothing is erased
      else
        TeamHub.flash("#{who} جان يعدّل على «#{object_label(oid)}» قبلك، فخليت نسخته. انتظر يخلص وعدّل بعده.")
      end
      # The WS object event may still be behind the HTTP conflict response.
      if server
        enqueue(server.merge('force' => true, '_refresh' => true))
      else
        enqueue('oid' => oid, 'kind' => oid == LOOSE_OID ? 'loose' : (oid.start_with?('d_') ? 'definition' : 'component'),
                'force' => true, '_refresh' => true)
      end
    end
  end
end
