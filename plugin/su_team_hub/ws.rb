# Minimal WebSocket client (RFC 6455) for SketchUp's Ruby, without threads:
# a non-blocking socket pumped by a 15 ms UI timer, so SketchUp never freezes
# while connecting or waiting. Text frames only (JSON), client frames masked,
# answers server pings, handles fragmented messages.

require 'socket'
require 'securerandom'
require 'base64'
require 'digest/sha1'
require 'uri'
require 'json'

module TeamHub
  class WSConn
    PUMP = 0.015
    GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'.freeze

    attr_reader :state # :connecting, :handshake, :open, :closed

    def initialize(url, on_open: nil, on_message: nil, on_close: nil)
      @uri = URI.parse(url)
      @on_open = on_open
      @on_message = on_message
      @on_close = on_close
      @rbuf = String.new(encoding: Encoding::BINARY)
      @wbuf = String.new(encoding: Encoding::BINARY)
      @frag = nil
      @state = :closed
    end

    def open?
      @state == :open
    end

    def start
      host = @uri.host
      port = @uri.port || 80
      addr = Socket.sockaddr_in(port, host)
      @sock = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
      @sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      @state = :connecting
      @started = Time.now
      begin
        @sock.connect_nonblock(addr)
        handshake
      rescue IO::WaitWritable, Errno::EINPROGRESS, Errno::EALREADY
        nil # finishes in pump
      end
      @timer = UI.start_timer(PUMP, true) { pump }
      self
    rescue StandardError => e
      fail_with(e)
      self
    end

    def send_json(obj)
      send_frame(0x1, JSON.generate(obj).b)
    end

    def close
      return if @state == :closed
      send_frame(0x8, ''.b) rescue nil
      flush rescue nil
      shutdown('closed by client')
    end

    private

    def handshake
      @key = Base64.strict_encode64(SecureRandom.random_bytes(16))
      path = @uri.request_uri
      req = "GET #{path} HTTP/1.1\r\nHost: #{@uri.host}:#{@uri.port}\r\nUpgrade: websocket\r\n" \
            "Connection: Upgrade\r\nSec-WebSocket-Key: #{@key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
      @wbuf << req.b
      @state = :handshake
    end

    def pump
      return if @state == :closed
      if @state == :connecting
        _, w, = IO.select(nil, [@sock], nil, 0)
        return shutdown('connect timeout') if w.nil? && Time.now - @started > 5
        return unless w
        err = @sock.getsockopt(Socket::SOL_SOCKET, Socket::SO_ERROR).int
        return shutdown("connect failed (#{err})") unless err.zero?
        handshake
      end
      flush
      read_available
    rescue StandardError => e
      fail_with(e)
    end

    def flush
      until @wbuf.empty?
        n = @sock.write_nonblock(@wbuf, exception: false)
        break if n == :wait_writable
        @wbuf = @wbuf.byteslice(n..-1) || String.new(encoding: Encoding::BINARY)
      end
    end

    def read_available
      loop do
        chunk = @sock.read_nonblock(65_536, exception: false)
        break if chunk == :wait_readable
        return shutdown('server closed') if chunk.nil?
        @rbuf << chunk
      end
      if @state == :handshake
        i = @rbuf.index("\r\n\r\n")
        return unless i
        head = @rbuf.byteslice(0, i)
        @rbuf = @rbuf.byteslice(i + 4..-1) || String.new(encoding: Encoding::BINARY)
        accept = Base64.strict_encode64(Digest::SHA1.digest(@key + GUID))
        unless head.start_with?('HTTP/1.1 101') && head.include?(accept)
          return shutdown("handshake refused: #{head.lines.first.to_s.strip}")
        end
        @state = :open
        @on_open&.call
      end
      parse_frames if @state == :open
    end

    def parse_frames
      loop do
        return if @rbuf.bytesize < 2
        b0, b1 = @rbuf.getbyte(0), @rbuf.getbyte(1)
        fin = b0 & 0x80 != 0
        op = b0 & 0x0f
        masked = b1 & 0x80 != 0
        len = b1 & 0x7f
        off = 2
        if len == 126
          return if @rbuf.bytesize < 4
          len = @rbuf.byteslice(2, 2).unpack1('n')
          off = 4
        elsif len == 127
          return if @rbuf.bytesize < 10
          len = @rbuf.byteslice(2, 8).unpack1('Q>')
          off = 10
        end
        mask = nil
        if masked
          return if @rbuf.bytesize < off + 4
          mask = @rbuf.byteslice(off, 4).bytes
          off += 4
        end
        return if @rbuf.bytesize < off + len
        payload = @rbuf.byteslice(off, len)
        @rbuf = @rbuf.byteslice(off + len..-1) || String.new(encoding: Encoding::BINARY)
        payload = payload.bytes.each_with_index.map { |c, i| c ^ mask[i % 4] }.pack('C*') if mask
        case op
        when 0x0 # continuation
          next unless @frag
          @frag << payload
          deliver(@frag) if fin
          @frag = nil if fin
        when 0x1
          fin ? deliver(payload) : (@frag = payload.dup)
        when 0x8
          return shutdown('server closed')
        when 0x9
          send_frame(0xA, payload)
        end
      end
    end

    def deliver(bytes)
      msg = JSON.parse(bytes.force_encoding('UTF-8'))
      @on_message&.call(msg)
    rescue JSON::ParserError
      nil
    end

    def send_frame(op, payload)
      return false unless @state == :open || op == 0x8
      head = [0x80 | op].pack('C')
      n = payload.bytesize
      head << if n < 126
                [0x80 | n].pack('C')
              elsif n < 65_536
                [0x80 | 126, n].pack('Cn')
              else
                [0x80 | 127, n].pack('CQ>')
              end
      key = SecureRandom.random_bytes(4)
      kb = key.bytes
      masked = payload.bytes.each_with_index.map { |c, i| c ^ kb[i % 4] }.pack('C*')
      @wbuf << head.b << key << masked
      flush
      true
    end

    def fail_with(e)
      shutdown("#{e.class}: #{e.message}")
    end

    def shutdown(reason)
      was = @state
      @state = :closed
      UI.stop_timer(@timer) if @timer
      @timer = nil
      @sock&.close rescue nil
      @sock = nil
      @on_close&.call(reason) if was != :closed
    end
  end
end
