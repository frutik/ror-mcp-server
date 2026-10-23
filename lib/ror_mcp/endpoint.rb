# frozen_string_literal: true

require "json"
require "stringio"

module RorMcp
  # Rack app serving one server over Streamable HTTP (django-mcp-server's
  # MCPServerStreamableHttpView + DjangoMCP.handle_django_request):
  #
  #   authenticate → 401 + WWW-Authenticate: Bearer when it returns nil
  #   DELETE       → forget the session, 200
  #   stateful     → Mcp-Session-Id rules: unknown id 404; no id: issue one on
  #                  `initialize`, otherwise 400
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
      if server.authenticator
        context = server.authenticator.call(request)
        return text_response(401, "Unauthorized", "www-authenticate" => "Bearer") unless context

        # The SDK hands this to tools as server_context[:auth_info].
        env[MCP::Server::OAuth::ENV_KEY] = context
      end

      return delete_session(server, env) if env["REQUEST_METHOD"] == "DELETE"
      return server.transport.call(env) if server.stateless?

      session_id = env[SESSION_ENV].to_s
      if !session_id.empty?
        return text_response(404, "Session not found") unless server.sessions.exists?(session_id)
      elsif initialize_request?(env)
        session_id = server.sessions.create
      else
        return text_response(400, "Session required for stateful server")
      end

      # The SDK runs stateless and must not try to resolve our session id.
      env.delete(SESSION_ENV)
      status, headers, body = server.transport.call(env)
      [status, headers.merge(SESSION_HEADER => session_id), body]
    ensure
      RorMcp.current_request = nil
    end

    def inspect
      "#<#{self.class.name} #{@server_key}>"
    end

    private

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
      env["rack.input"] = StringIO.new(body)
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
