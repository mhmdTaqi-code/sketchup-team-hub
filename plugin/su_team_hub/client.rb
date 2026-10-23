# Non-blocking JSON client for the Team Hub server.
# Uses Sketchup::Http so network calls never freeze the SketchUp UI.

require 'json'
require 'uri'

module TeamHub
  class Client
    METHODS = {
      get: Sketchup::Http::GET,
      post: Sketchup::Http::POST,
      delete: Sketchup::Http::DELETE,
    }.freeze

    attr_reader :server
    attr_accessor :token

    def self.normalize(server)
      s = server.to_s.strip.sub(%r{/+\z}, '')
      s = "http://#{s}" unless s.empty? || s =~ %r{\Ahttps?://}i
      s
    end

    def initialize(server, token = nil)
      @server = Client.normalize(server)
      @token = token
      # Sketchup::Http::Request objects must stay referenced until they finish,
      # otherwise the garbage collector cancels them.
      @inflight = {}
    end

    # Calls the block with (status, data). status 0 = network failure/timeout.
    def request(method, path, body = nil, timeout: 30, &block)
      req = Sketchup::Http::Request.new(@server + path, METHODS.fetch(method))
      headers = { 'Content-Type' => 'application/json', 'Accept' => 'application/json',
                  'X-TeamHub-Plugin' => PLUGIN_VERSION }
      headers['Authorization'] = "Bearer #{@token}" if @token
      req.headers = headers
      req.body = JSON.generate(body) if body
      key = req.object_id
      finished = false
      @inflight[key] = req

      finish = lambda do |status, data|
        next if finished
        finished = true
        @inflight.delete(key)
        begin
          block&.call(status, data)
        rescue StandardError => e
          TeamHub.log_error(e)
        end
      end

      req.start do |_request, response|
        status = response.status_code.to_i
        data = nil
        text = response.body.to_s.dup.force_encoding('UTF-8')
        begin
          data = JSON.parse(text) unless text.empty?
        rescue JSON::ParserError
          data = nil
        end
        finish.call(status, data)
      end

      UI.start_timer(timeout, false) do
        unless finished
          begin
            req.cancel
          rescue StandardError
            nil
          end
          finish.call(0, { 'error' => 'timeout' })
        end
      end
      req
    rescue StandardError => e
      TeamHub.log_error(e)
      block&.call(0, { 'error' => e.message })
      nil
    end

    def self.q(value)
      URI.encode_www_form_component(value.to_s)
    end
  end
end
