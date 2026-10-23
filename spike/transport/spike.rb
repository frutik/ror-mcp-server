# frozen_string_literal: true

# M0 transport spike (PLAN §8, assumptions A2–A8 in §10.1). Throwaway code:
# what it proves feeds RorMcp::Endpoint (C5) and RorMcp::Server (C4) in M1.
#
# Question: can the official `mcp` gem serve MCP from a plain Rack app with the
# same HTTP contract as django-mcp-server (§1A.2)? Answer, as built here:
#   - MCP::Server::Transports::StreamableHTTPTransport is itself a Rack app;
#     run it with stateless: true + enable_json_response: true and it answers
#     with plain JSON, never SSE, and needs no SDK session.
#   - django-mcp-server's session rules (400 / 404 / Mcp-Session-Id on
#     initialize / DELETE) and auth (401) sit in front of it, exactly as
#     DjangoMCP.handle_django_request sits in front of the Python SDK.
#   - The authenticate block's result travels in env["mcp.auth_info"] and
#     reaches tools as server_context[:auth_info].

require "json"
require "securerandom"
require "rack"
require "mcp"

module TransportSpike
  SESSION_HEADER = "mcp-session-id"
  SESSION_ENV = "HTTP_MCP_SESSION_ID"

  # Process-local session store; M1 makes this pluggable (SessionStore::{Memory,Cache}).
  class MemorySessions
    def initialize
      @ids = {}
      @mutex = Mutex.new
    end

    def create = @mutex.synchronize { SecureRandom.hex(16).tap { |id| @ids[id] = true } }
    def exists?(id) = @mutex.synchronize { @ids.key?(id) }
    def delete(id) = @mutex.synchronize { @ids.delete(id) }
  end

  # Rack endpoint: auth → session rules → SDK transport (stateless, JSON responses).
  class Endpoint
    def initialize(server, stateless: false, authenticate: nil, sessions: MemorySessions.new)
      @stateless = stateless
      @authenticate = authenticate
      @sessions = sessions
      # Host/Origin checks are left to Rails (config.hosts / HostAuthorization): the SDK
      # default only accepts loopback Host headers, which would 403 any real deployment.
      @transport = MCP::Server::Transports::StreamableHTTPTransport.new(
        server, stateless: true, enable_json_response: true, dns_rebinding_protection: false,
      )
      server.transport = @transport
    end

    def call(env)
      request = Rack::Request.new(env)

      if @authenticate
        context = @authenticate.call(request)
        return [401, { "www-authenticate" => "Bearer", "content-type" => "text/plain" }, ["Unauthorized"]] unless context

        env[MCP::Server::OAuth::ENV_KEY] = context
      end

      return delete_session(env) if request.delete?
      return @transport.call(env) if @stateless

      session_id = env[SESSION_ENV]
      if session_id && !session_id.empty?
        return [404, { "content-type" => "text/plain" }, ["Session not found"]] unless @sessions.exists?(session_id)
      elsif initialize_request?(env)
        session_id = @sessions.create
      else
        return [400, { "content-type" => "text/plain" }, ["Session required for stateful server"]]
      end

      # The SDK runs stateless: strip our session header so it does not try to resolve it.
      env.delete(SESSION_ENV)
      status, headers, body = @transport.call(env)
      [status, headers.merge(SESSION_HEADER => session_id), body]
    end

    private

    def delete_session(env)
      session_id = env[SESSION_ENV]
      @sessions.delete(session_id) if !@stateless && session_id
      [200, { "content-type" => "text/plain" }, ["Session destroyed"]]
    end

    # Reads the body once and puts it back, so the transport can read it again.
    def initialize_request?(env)
      input = env["rack.input"]
      return false unless input

      body = input.read
      env["rack.input"] = StringIO.new(body)
      JSON.parse(body)["method"] == "initialize"
    rescue JSON::ParserError
      false
    end
  end

  # What FastMCP (django-mcp-server) advertises; the SDK default is tools/prompts/resources/logging.
  FASTMCP_CAPABILITIES = {
    experimental: {},
    prompts: { listChanged: false },
    resources: { subscribe: false, listChanged: false },
    tools: { listChanged: false },
  }.freeze

  module_function

  # Two servers shaped like the reference app's (spec/parity/django_app), with
  # just enough tools to probe the SDK: plain text, errors, embedded resources
  # and the per-request auth context.
  def default_server
    instructions = "Reference shop server for ror-mcp-server parity tests. " \
                   "Query the collections with query_data_collections."
    MCP::Server.new(
      name: "parity-shop",
      instructions: instructions,
      capabilities: FASTMCP_CAPABILITIES,
      tools: [
        instructions_tool(instructions),
        MCP::Tool.define(
          name: "add", description: "Add two integers.",
          input_schema: { properties: { a: { type: "integer" }, b: { type: "integer" } }, required: ["a", "b"] },
        ) { |a:, b:| MCP::Tool::Response.new([{ type: "text", text: (a + b).to_s }]) },
        MCP::Tool.define(
          name: "explode", description: "Always fails; exercises the tool error path.",
          input_schema: { properties: { reason: { type: "string" } }, required: ["reason"] },
        ) { |reason:| raise ArgumentError, "exploded: #{reason}" },
        MCP::Tool.define(
          name: "explode_as_tool_error", description: "Fails the FastMCP way: an isError result.",
        ) { MCP::Tool::Response.new([{ type: "text", text: "Error executing tool explode: exploded" }], error: true) },
        MCP::Tool.define(
          name: "embedded_resource", description: "Returns text plus an embedded JSON resource.",
        ) do
          MCP::Tool::Response.new([
            { type: "text", text: "Results attached" },
            { type: "resource", resource: { uri: "resource://query_result/json", mimeType: "application/json",
                                             text: '[{"id":1}]' } },
          ])
        end,
      ],
    )
  end

  def analytics_server
    instructions = "Reporting server. Orders come back as CSV."
    MCP::Server.new(
      name: "parity-analytics",
      instructions: instructions,
      capabilities: FASTMCP_CAPABILITIES,
      tools: [
        instructions_tool(instructions),
        MCP::Tool.define(name: "whoami", description: "Echoes the authenticate block's context.") do |server_context:|
          MCP::Tool::Response.new([{ type: "text", text: server_context[:auth_info].to_json }])
        end,
      ],
    )
  end

  def instructions_tool(instructions)
    MCP::Tool.define(
      name: "get_server_instructions",
      description: "Return MCP server instructions (if any). Always call first.",
    ) { MCP::Tool::Response.new([{ type: "text", text: instructions }]) }
  end

  def bearer(token)
    ->(request) { request.get_header("HTTP_AUTHORIZATION") == "Bearer #{token}" ? { token: "analytics" } : nil }
  end

  # Mounted like the reference app's urls.py: /mcp and /mcp/analytics.
  def app(token: "parity-secret")
    default = Endpoint.new(default_server)
    analytics = Endpoint.new(analytics_server, stateless: true, authenticate: bearer(token))
    Rack::Builder.new do
      map("/mcp/analytics") { run analytics }
      map("/mcp") { run default }
    end
  end
end
