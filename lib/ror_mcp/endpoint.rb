# frozen_string_literal: true

require "json"
require "stringio"

module RorMcp
  # Rack app serving one server over Streamable HTTP (django-mcp-server's
  # MCPServerStreamableHttpView + DjangoMCP.handle_django_request):
  #
  #   Origin       → 403 for a browser page on an origin not allowed (MCP transport spec)
  #   authenticate → 401 + WWW-Authenticate: Bearer when it returns nil
  #   POST body    → 413 past max_request_bytes, read with that bound before anything parses it
  #   DELETE       → forget the session, 200
  #   stateful     → Mcp-Session-Id rules: unknown id 404; no id: issue one when
  #                  `initialize` succeeds, otherwise 400
  #   then the SDK transport (stateless, JSON responses) answers the request.
  #
  # The server is looked up per request, so routes can be drawn before
  # RorMcp.configure runs.
  class Endpoint
    SESSION_HEADER = "mcp-session-id"
    SESSION_ENV = "HTTP_MCP_SESSION_ID"

    attr_reader :server_key

    def initialize(server_key)
      @server_key = server_key.to_sym
    end

    def call(env)
      server = RorMcp.server(@server_key)

      request = build_request(env)
      RorMcp.current_request = request
      return text_response(403, "Origin not allowed") unless origin_allowed?(server, request)

      if server.authenticator
        context = server.authenticator.call(request)
        return text_response(401, "Unauthorized", "www-authenticate" => "Bearer") unless context

        # The SDK hands this to tools as server_context[:auth_info].
        env[MCP::Server::OAuth::ENV_KEY] = context
      end

      return text_response(413, "Request body too large") unless bound_body!(env)
      return delete_session(server, env) if env["REQUEST_METHOD"] == "DELETE"
      return server.transport.call(env) if server.stateless?

      session_id = env[SESSION_ENV].to_s
      if !session_id.empty?
        return text_response(404, "Session not found") unless server.sessions.exists?(session_id)

        # The SDK runs stateless and must not try to resolve our session id.
        env.delete(SESSION_ENV)
        status, headers, body = server.transport.call(env)
        [status, headers.merge(SESSION_HEADER => session_id), body]
      elsif initialize_request?(env)
        start_session(server, env)
      else
        text_response(400, "Session required for stateful server")
      end
    ensure
      RorMcp.current_request = nil
    end

    def inspect
      "#<#{self.class.name} #{@server_key}>"
    end

    private

    # Browsers send Origin, other MCP clients don't. A page may call the server
    # from its own origin or a listed one; anything else could be another site
    # driving the user's browser. ("null" comes from sandboxed and file:// pages.)
    def origin_allowed?(server, request)
      origin = request.get_header("HTTP_ORIGIN")
      return true if origin.nil? || server.allowed_origins == :any

      origin = origin.downcase.chomp("/")
      origin == request.base_url.downcase || server.allowed_origins.include?(origin)
    end

    # A session exists once `initialize` succeeded: a refused or malformed one
    # allocates nothing.
    def start_session(server, env)
      status, headers, body = server.transport.call(env)
      parts = body.enum_for(:each).to_a # a Rack body promises #each, not #map
      body.close if body.respond_to?(:close)
      payload = JSON.parse(parts.join)
      return [status, headers, parts] unless status == 200 && payload.is_a?(Hash) && payload.key?("result")

      [status, headers.merge(SESSION_HEADER => server.sessions.create), parts]
    rescue JSON::ParserError
      [status, headers, parts]
    end

    # Reads a POST body once, at most max_request_bytes (one more tells it is
    # over), before anything parses it; the transport then reads this copy.
    def bound_body!(env)
      limit = RorMcp.configuration.max_request_bytes
      input = env["rack.input"]
      return true if limit.nil? || input.nil? || env["REQUEST_METHOD"] != "POST"
      return false if env["CONTENT_LENGTH"].to_i > limit

      body = input.read(limit + 1).to_s
      return false if body.bytesize > limit

      env["rack.input"] = StringIO.new(body)
      true
    end

    def delete_session(server, env)
      session_id = env[SESSION_ENV].to_s
      server.sessions.delete(session_id) if !server.stateless? && !session_id.empty?
      text_response(200, "Session destroyed")
    end

    # Reads the body and puts it back, so the transport can read it again.
    def initialize_request?(env)
      input = env["rack.input"]
      return false unless input

      body = input.read
      env["rack.input"] = StringIO.new(body) # Rack 3 inputs needn't rewind
      payload = JSON.parse(body)
      payload.is_a?(Hash) && payload["method"] == "initialize"
    rescue JSON::ParserError
      false
    end

    def build_request(env)
      defined?(ActionDispatch::Request) ? ActionDispatch::Request.new(env) : Rack::Request.new(env)
    end

    def text_response(status, text, headers = {})
      [status, { "content-type" => "text/plain" }.merge(headers), [text]]
    end
  end
end
