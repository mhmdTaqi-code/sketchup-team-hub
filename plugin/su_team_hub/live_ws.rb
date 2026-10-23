# WebSocket transport for the live session: the server pushes every event the
# moment it happens and my operations go out on the same open connection.
# If the socket can't be opened or drops, the long-poll loop (realtime.rb)
# takes over by itself and the socket is retried in the background.

module TeamHub
  class Session
    WS_RETRY = 3.0

    def ws_open?
      @ws && @ws.open?
    end

    def ws_url
      base = @client.server.sub(%r{\Ahttp}, 'ws')
      "#{base}/ws?token=#{Client.q(@client.token)}&project=#{pid}&client=sketchup"
    end

    def start_ws
      return if @stopped || (@ws && @ws.state != :closed)
      @ws_tried_at = Time.now
      @ws = WSConn.new(ws_url,
                       on_open: -> { guard { ws_opened } },
                       on_message: ->(m) { guard { ws_message(m) } },
                       on_close: ->(why) { guard { ws_closed(why) } })
      @ws.start
    end

    def stop_ws
      ws = @ws
      @ws = nil
      ws&.close
    end

    def ws_opened
      @status = :online
      @transport = :websocket
      send_ws_status
      ws_ping
      catch_up # anything that happened before the socket was up
      resend_inflight_deltas
      when_idle { pump_pushes }
      run_jobs
      notify
    end

    def ws_closed(why)
      TeamHub.log_sync("WS closed: #{why}") if why && @transport == :websocket || why.to_s =~ /Error|Errno/
      @transport = :longpoll
      requeue_inflight_deltas
      return if @stopped
      UI.start_timer(WS_RETRY, false) { guard { start_ws } }
      poll # long-poll keeps things live meanwhile
    end

    def ws_message(m)
      case m['type']
      when 'hello'
        @online = m['online'] if m['online']
        catch_up if m['seq'].to_i > @seq
      when 'presence'
        @online = m['online'] || @online
        notify
      when 'pong'
        @ping_ms = ((Time.now.to_f * 1000) - m['t'].to_f).round if m['t']
        if !connected?
          @status = :online
          when_idle { pump_pushes }
          run_jobs
        end
        catch_up if m['seq'].to_i > @seq
      when 'ack'
        delta_acked(m)
      else
        return unless m['seq']
        seq = m['seq'].to_i
        return if seq <= @seq
        if seq == @seq + 1 && !@catching
          handle_event(m)
          refresh_overlay
          notify
        else
          (@ws_buffer ||= []) << m # a gap: fetch what's missing first
          catch_up
        end
      end
    end

    # Fetch missed events over HTTP, then replay anything buffered meanwhile.
    def catch_up
      return if @catching || @stopped
      @catching = true
      @client.request(:get, "/api/projects/#{pid}/events?since=#{@seq}&limit=5000&client=sketchup", nil, timeout: 30) do |st, data|
        @catching = false
        next if @stopped
        if st == 200 && data
          set_claims(data['claims']) if data['claims']
          data['events'].each { |e| handle_event(e) }
          buf = (@ws_buffer || []).sort_by { |e| e['seq'].to_i }
          @ws_buffer = []
          buf.each do |e|
            next if e['seq'].to_i <= @seq
            if e['seq'].to_i == @seq + 1
              handle_event(e)
            else
              @ws_buffer << e
            end
          end
          # A page is capped at 5,000 events. Never jump over the next page to
          # replay a newer WS event, even when the socket buffer is nonempty.
          if data['seq'].to_i > @seq || !@ws_buffer.empty?
            UI.start_timer(0, false) { guard { catch_up } }
          end
          refresh_overlay
          notify
        else
          UI.start_timer(1, false) { guard { catch_up } }
        end
      end
    end

    def ws_ping
      return unless ws_open?
      @ws.send_json('type' => 'ping', 't' => (Time.now.to_f * 1000).round, 'ping' => @ping_ms)
    end

    def send_ws_status
      return unless ws_open?
      @ws.send_json('type' => 'status', 'status' => { 'text' => status_text },
                    'app' => { 'su' => TeamHub.su_version_label, 'plugin' => PLUGIN_VERSION, 'ping' => @ping_ms })
    end

    # ------------------------------------------------------------ deltas over the socket

    def delta_inflight
      @delta_inflight ||= {}
    end

    def pump_deltas
      return if @stopped || (@delta_out || []).empty?
      if ws_open?
        until @delta_out.empty?
          d = @delta_out.shift
          id = (@delta_id = (@delta_id || 0) + 1)
          delta_inflight[id] = d
          @ws.send_json(d.merge('type' => 'delta', 'id' => id))
        end
        return
      end
      pump_deltas_http
    end

    def delta_acked(m)
      d = delta_inflight.delete(m['id'])
      return if m['ok'] || d.nil?
      holder = m['user']
      TeamHub.flash("ما انرسل تعديلك: #{holder ? "محجوز من #{holder['display_name']}" : m['error']}")
      mark_checkpoint_needed(d['ctx'])
    end

    def requeue_inflight_deltas
      return if delta_inflight.empty?
      pending = delta_inflight.sort.map { |_, d| d }
      @delta_inflight = {}
      @delta_out = pending + (@delta_out || [])
    end

    def resend_inflight_deltas
      requeue_inflight_deltas
      pump_deltas
    end

    # Fallback when the socket is down: one HTTP request at a time, in order.
    def pump_deltas_http
      return if @delta_sending || @stopped || (@delta_out || []).empty?
      d = @delta_out.first
      @delta_sending = true
      @client.request(:post, "/api/projects/#{pid}/delta", d, timeout: 30) do |st, data|
        @delta_sending = false
        next if @stopped
        if st == 200
          @delta_out.shift
          @status = :online
        elsif st.zero?
          @status = :offline
          UI.start_timer(2, false) { guard { pump_deltas } }
          next
        else
          @delta_out.shift
          holder = data && data['user']
          TeamHub.flash("ما انرسل تعديلك: #{holder ? "محجوز من #{holder['display_name']}" : (data && data['error'])}")
          mark_checkpoint_needed(d['ctx'])
        end
        pump_deltas
        notify
      end
    end
  end
end
