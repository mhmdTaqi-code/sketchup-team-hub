# Real-time layer:
#   * long-poll: the server holds the request until something happens, so a
#     teammate's change arrives within milliseconds, not on the next poll;
#   * live claims: what I'm working on is marked "being edited by me" and is
#     locked on everyone else's screen until I'm done (no overwrites);
#   * conflicts never delete work: both versions are kept;
#   * ping + presence;
#   * transformations are never read while an edit context is open (SketchUp
#     reports them in edit space then — that was the "teleport").

require 'securerandom'

module TeamHub
  class Session
    LONG_POLL_WAIT = 20      # seconds the server may hold a poll
    TICK_INTERVAL = 2.0      # claims renew/release + presence
    PING_EVERY = 5.0
    CLAIM_IDLE = 8.0         # seconds without activity before a claim is released

    attr_reader :ping_ms

    # ------------------------------------------------------------ long-poll loop

    def start_polling
      UI.stop_timer(@poll_timer) if @poll_timer
      UI.stop_timer(@sweep_timer) if @sweep_timer
      UI.stop_timer(@tick_timer) if @tick_timer
      @poll_timer = nil
      @sweep_timer = UI.start_timer(SWEEP_INTERVAL, true) { guard { request_sweep } }
      @tick_timer = UI.start_timer(TICK_INTERVAL, true) { guard { live_tick } }
      @poll_gen = (@poll_gen || 0) + 1
      @polling = false
      start_ws # real-time channel; long-poll covers until it's open / if it drops
      poll
    end

    def poll
      return if @polling || @stopped || ws_open?
      @polling = true
      gen = @poll_gen
      path = "/api/projects/#{pid}/events?since=#{@seq}&limit=500&client=sketchup&wait=#{LONG_POLL_WAIT}" \
             "&su=#{Client.q(TeamHub.su_version_label)}&pv=#{Client.q(PLUGIN_VERSION)}"
      path += "&ping=#{@ping_ms}" if @ping_ms
      text = status_text
      path += "&status=#{Client.q(text)}" if text
      @client.request(:get, path, nil, timeout: LONG_POLL_WAIT + 15) do |st, data|
        next if gen != @poll_gen
        @polling = false
        next if @stopped
        if st == 200 && data
          was_offline = !connected?
          @status = :online
          @online = data['online'] if data['online']
          set_claims(data['claims']) if data['claims']
          data['events'].each { |e| handle_event(e) }
          refresh_overlay if !@recent.empty? || data['events'].any?
          if was_offline
            when_idle { pump_pushes }
            run_jobs
          end
          notify
          UI.start_timer(0, false) { guard { poll } } # straight back into the next long-poll
        elsif st == 401
          TeamHub.auth_expired
        else
          @status = :offline
          notify
          UI.start_timer(2, false) { guard { poll } }
        end
      end
    end

    # ------------------------------------------------------------ ping + presence + claims tick

    def live_tick
      return if @stopped || !@loaded
      now = Time.now
      if ws_open?
        if @last_ping_at.nil? || now - @last_ping_at >= PING_EVERY
          @last_ping_at = now
          ws_ping
          send_ws_status
        elsif status_text != @last_status_sent
          send_ws_status
        end
        @last_status_sent = status_text
        tick_claims(now)
        return
      end
      if @last_ping_at.nil? || now - @last_ping_at >= PING_EVERY
        @last_ping_at = now
        t0 = Time.now
        @client.request(:get, '/api/ping', nil, timeout: 10) do |st, _|
          @ping_ms = st == 200 ? ((Time.now - t0) * 1000).round : nil
          send_presence
        end
      end
      tick_claims(now)
    end

    def send_presence
      body = { 'client' => 'sketchup', 'status' => status_text, 'su' => TeamHub.su_version_label,
               'plugin' => PLUGIN_VERSION, 'ping' => @ping_ms }
      @client.request(:post, "/api/projects/#{pid}/presence", body, timeout: 10) do |st, data|
        if st == 200 && data && data['online']
          @online = data['online']
          notify
        end
      end
    end

    # ------------------------------------------------------------ claims

    def claims
      @claims ||= {}
    end

    def my_claims
      @my_claims ||= {} # oid => last activity
    end

    def claimed_by_other?(oid)
      uid = claims[oid]
      !uid.nil? && uid != my_id
    end

    def claim_holder(oid)
      @users[claims[oid]] || {}
    end

    def set_claims(list)
      fresh = {}
      list.each { |c| fresh[c['oid']] = c['user_id'] }
      changed = (fresh.keys | claims.keys).reject { |o| fresh[o] == claims[o] }
      @claims = fresh
      when_idle { apply_local_locks(changed) } unless changed.empty?
    end

    # Something I'm working on: claim it (or keep the claim alive).
    def note_activity(oid, &on_denied)
      return if viewer? || oid.nil?
      known = my_claims.key?(oid)
      my_claims[oid] = Time.now
      return if known && claims[oid] == my_id
      @client.request(:post, "/api/projects/#{pid}/claim", { 'oids' => [oid] }, timeout: 10) do |st, data|
        next unless st == 200 && data
        data['granted'].each { |o| claims[o] = my_id }
        data['denied'].each do |d|
          my_claims.delete(d['oid'])
          claims[d['oid']] = d['user']['id'] if d['user']
          @users[d['user']['id']] ||= d['user'] if d['user']
          on_denied&.call(d['user'] || {})
        end
        refresh_overlay
      end
    end

    def tick_claims(now)
      return if my_claims.empty?
      editing = editing_root_oid
      keep = []
      drop = []
      my_claims.each do |oid, at|
        busy = oid == editing || @pushing[oid] || @push_wanted.key?(oid) || (now - at) < CLAIM_IDLE
        busy ? keep << oid : drop << oid
      end
      drop.each { |o| my_claims.delete(o) }
      return if keep.empty? && drop.empty?
      @client.request(:post, "/api/projects/#{pid}/claim", { 'oids' => keep, 'release' => drop }, timeout: 10) do |st, data|
        next unless st == 200 && data
        data['released'].each { |o| claims.delete(o) if claims[o] == my_id }
        refresh_overlay
      end
    end

    def editing_root_oid
      root = (@model.active_path || []).first
      root && @eid_to_oid[root.entityID]
    rescue StandardError
      nil
    end

    # ------------------------------------------------------------ transformations (teleport fix)

    # While a Group/Component is open for editing, SketchUp reports
    # transformations in that edit space. A top-level object can't be moved
    # from inside an edit context anyway, so use the last value read outside.
    def t_of(ent, oid)
      @last_t ||= {}
      path = @model.active_path
      if path.nil? || path.empty?
        @last_t[oid] = ent.transformation.to_a
      else
        @last_t[oid] ||
          (path.first == ent && path.size == 1 ? @model.edit_transform.to_a : ent.transformation.to_a)
      end
    end

    # ------------------------------------------------------------ conflicts: keep both versions

    def keep_both(oid, other)
      who = (other && other['display_name']) || 'عضو ثاني'
      server = @objects[oid]
      if oid == LOOSE_OID
        keep_my_loose(who)
      elsif (ent = live_entity(oid)) && !oid.start_with?('d_')
        model_op('Team Hub: نسختي') do
          copy = if ent.is_a?(Sketchup::Group)
                   ent.copy
                 else
                   @model.entities.add_instance(ent.definition, ent.transformation)
                 end
          copy.name = "#{display_name(ent)} (نسخة #{@me['display_name']})"
          copy.set_attribute(DICT, 'oid', "o#{SecureRandom.hex(10)}")
          copy.delete_attribute(DICT, 'rev')
          copy.locked = false
          @added << copy
        end
        process_added
      end
      TeamHub.flash("#{who} عدّل نفس الشي بنفس الوقت. ما انمسح شي: خليت نسخته بمكانها، ونسختك جنبها باسم «نسخة #{@me['display_name']}».")
      enqueue(server.merge('force' => true)) if server && !server['deleted']
    end

    # My new loose lines/faces become their own Group, then the team's loose
    # geometry comes back as it is on the server.
    def keep_my_loose(_who)
      base = @loose_ids || {}
      mine = loose_entities.reject { |e| base[e.entityID] }
      return if mine.empty?
      model_op('Team Hub: رسمتي') do
        g = @model.entities.add_group(mine)
        g.name = "رسمة #{@me['display_name']}"
        @added << g
      end
      process_added
    end

    def remember_loose_ids
      @loose_ids = {}
      loose_entities.each { |e| @loose_ids[e.entityID] = true }
    end
  end
end
