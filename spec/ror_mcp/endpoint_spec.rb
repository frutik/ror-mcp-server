# frozen_string_literal: true

require "rack/test"

# The HTTP contract of django-mcp-server (PLAN §1A.2), as recorded from the
# reference app in spec/parity/expected/django/http.json, plus what the SDK
# does underneath (spike/transport/README.md).
RSpec.describe RorMcp::Endpoint do
  include Rack::Test::Methods

  let(:app) do
    Rack::Builder.new do
      map("/mcp/analytics") { run RorMcp.endpoint(:analytics) }
      map("/mcp") { run RorMcp.endpoint }
    end
  end
  let(:auth) { { "Authorization" => "Bearer s3cret" } }

  before do
    RorMcp.reset!
    RorMcp.configure do |c|
      c.default_server name: "parity-shop", instructions: "Reference shop server."
      c.server :analytics, name: "parity-analytics", instructions: "Reporting server.", stateless: true,
                           authenticate: ->(request) { request.get_header("HTTP_AUTHORIZATION") == "Bearer s3cret" && { token: "analytics" } }
    end

    RorMcp.server(:default).add_tool(MCP::Tool.define(
      name: "add", description: "Add two integers.",
      input_schema: { properties: { a: { type: "integer" }, b: { type: "integer" } }, required: %w[a b] },
    ) { |a:, b:| MCP::Tool::Response.new([{ type: "text", text: (a + b).to_s }]) })
    RorMcp.server(:default).add_tool(MCP::Tool.define(name: "explode", description: "Fails.") { raise ArgumentError, "boom" })
    RorMcp.server(:default).add_tool(MCP::Tool.define(name: "embedded_resource", description: "Resource.") do
      MCP::Tool::Response.new([
        { type: "text", text: "Results attached" },
        { type: "resource", resource: { uri: "resource://query_result/json", mimeType: "application/json", text: "[]" } },
      ])
    end)
    RorMcp.server(:analytics).add_tool(MCP::Tool.define(name: "whoami", description: "Auth context.") do |server_context:|
      MCP::Tool::Response.new([{ type: "text", text: server_context[:auth_info].to_json }])
    end)
  end

  after { RorMcp.reset! }

  def rpc(path, method, params = nil, session: nil, headers: {}, id: 1)
    payload = { jsonrpc: "2.0", method: method }
    payload[:params] = params if params
    payload[:id] = id if id
    env = { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json, text/event-stream" }
    env["HTTP_MCP_SESSION_ID"] = session if session
    headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }
    post path, JSON.generate(payload), env
    last_response
  end

  def initialize_params(version = "2025-03-26")
    { protocolVersion: version, capabilities: {}, clientInfo: { name: "spec", version: "0" } }
  end

  def json = JSON.parse(last_response.body)

  def open_session
    rpc("/mcp", "initialize", initialize_params)
    last_response.headers["mcp-session-id"].tap do |sid|
      rpc("/mcp", "notifications/initialized", session: sid, id: nil)
    end
  end

  def call_tool(name, arguments = {})
    rpc("/mcp", "tools/call", { name: name, arguments: arguments }, session: open_session)
    json
  end

  describe "initialize" do
    it "answers plain JSON and issues a session id" do
      rpc("/mcp", "initialize", initialize_params)
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to start_with("application/json")
      expect(last_response.headers["mcp-session-id"]).to match(/\A\h{32}\z/)
      expect(json["result"]).to include("serverInfo" => { "name" => "parity-shop", "version" => RorMcp::VERSION },
                                        "instructions" => "Reference shop server.")
    end

    it "advertises FastMCP's capability keys" do
      rpc("/mcp", "initialize", initialize_params)
      expect(json.dig("result", "capabilities").keys).to contain_exactly("experimental", "prompts", "resources", "tools")
    end

    it "negotiates the protocol versions current clients send" do
      %w[2025-03-26 2025-06-18 2025-11-25].each do |version|
        rpc("/mcp", "initialize", initialize_params(version))
        expect(json.dig("result", "protocolVersion")).to eq(version)
      end
    end

    it "leaves Host checks to Rails" do
      rpc("/mcp", "initialize", initialize_params, headers: { "Host" => "shop.example.com" })
      expect(last_response.status).to eq(200)
    end
  end

  describe "session rules" do
    it "answers 400 to a non-initialize request without a session" do
      expect(rpc("/mcp", "tools/list").status).to eq(400)
      expect(last_response.body).to eq("Session required for stateful server")
    end

    it "answers 404 to an unknown session" do
      expect(rpc("/mcp", "tools/list", session: "nope").status).to eq(404)
    end

    it "answers 202 to notifications and echoes the session id on requests" do
      sid = open_session
      expect(last_response.status).to eq(202)
      expect(rpc("/mcp", "tools/list", session: sid).status).to eq(200)
      expect(last_response.headers["mcp-session-id"]).to eq(sid)
    end

    it "forgets a session on DELETE" do
      sid = open_session
      delete "/mcp", {}, "HTTP_MCP_SESSION_ID" => sid
      expect(last_response.status).to eq(200)
      expect(rpc("/mcp", "tools/list", session: sid).status).to eq(404)
    end

    it "treats a malformed body as a request needing a session" do
      post "/mcp", "not json", "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(400)
    end
  end

  describe "tools" do
    it "lists get_server_instructions first, then registered tools" do
      rpc("/mcp", "tools/list", session: open_session)
      expect(json.dig("result", "tools").map { |t| t["name"] }).to eq(%w[get_server_instructions add explode embedded_resource])
    end

    it "answers get_server_instructions with the server instructions" do
      expect(call_tool("get_server_instructions").dig("result", "content")).to eq([{ "type" => "text", "text" => "Reference shop server." }])
    end

    it "returns tool content" do
      expect(call_tool("add", a: 2, b: 5).dig("result", "content", 0, "text")).to eq("7")
    end

    it "passes embedded resources through" do
      expect(call_tool("embedded_resource").dig("result", "content", 1, "resource", "uri")).to eq("resource://query_result/json")
    end

    it "reports missing arguments as an isError result" do
      expect(call_tool("add", a: 1)["result"]).to include("isError" => true)
    end

    # FastMCP answers both with isError results; RorMcp::Toolset bridges this in M5.
    it "turns an exception into a JSON-RPC error that hides the message (SDK behaviour)" do
      response = call_tool("explode")
      expect(response.dig("error", "code")).to eq(-32_603)
      expect(response.to_json).not_to include("boom")
    end
  end

  describe "a stateless server with its own authentication" do
    it "answers 401 with WWW-Authenticate: Bearer without a valid token" do
      expect(rpc("/mcp/analytics", "initialize", initialize_params).status).to eq(401)
      expect(last_response.headers["www-authenticate"]).to eq("Bearer")
      expect(rpc("/mcp/analytics", "initialize", initialize_params, headers: { "Authorization" => "Bearer x" }).status).to eq(401)
    end

    it "needs no session and issues none" do
      rpc("/mcp/analytics", "initialize", initialize_params, headers: auth)
      expect(last_response.status).to eq(200)
      expect(last_response.headers).not_to have_key("mcp-session-id")
      expect(rpc("/mcp/analytics", "tools/list", headers: auth).status).to eq(200)
    end

    it "hands the authenticate result to tools as server_context[:auth_info]" do
      rpc("/mcp/analytics", "tools/call", { name: "whoami", arguments: {} }, headers: auth)
      expect(json.dig("result", "content", 0, "text")).to eq('{"token":"analytics"}')
    end

    it "answers DELETE with 200 without touching sessions" do
      delete "/mcp/analytics", {}, "HTTP_AUTHORIZATION" => "Bearer s3cret"
      expect(last_response.status).to eq(200)
    end
  end

  describe "global authentication" do
    before do
      RorMcp.configure { |c| c.authenticate { |request| request.get_header("HTTP_AUTHORIZATION") == "Bearer global" && { user: 1 } } }
    end

    it "applies to servers without their own authenticate" do
      expect(rpc("/mcp", "initialize", initialize_params).status).to eq(401)
      expect(rpc("/mcp", "initialize", initialize_params, headers: { "Authorization" => "Bearer global" }).status).to eq(200)
    end

    it "is replaced by a server's own authenticate" do
      expect(rpc("/mcp/analytics", "initialize", initialize_params, headers: { "Authorization" => "Bearer global" }).status).to eq(401)
      expect(rpc("/mcp/analytics", "initialize", initialize_params, headers: auth).status).to eq(200)
    end
  end

  # MCP transport spec: servers must validate Origin and answer 403 for an invalid one.
  # rack-test requests come from http://example.org.
  describe "Origin" do
    def initialize_from(origin, path = "/mcp", headers: {})
      rpc(path, "initialize", initialize_params, headers: headers.merge("Origin" => origin)).status
    end

    it "accepts requests without Origin (non-browser clients) and from the server's own origin" do
      expect(rpc("/mcp", "initialize", initialize_params).status).to eq(200)
      expect(initialize_from("http://example.org")).to eq(200)
      expect(initialize_from("HTTP://Example.org/")).to eq(200)
    end

    it "refuses any other origin with 403, before authentication and for every method" do
      expect(initialize_from("https://evil.example")).to eq(403)
      expect(last_response.body).to eq("Origin not allowed")
      expect(initialize_from("https://evil.example", "/mcp/analytics")).to eq(403)
      expect(initialize_from("http://example.org:8080")).to eq(403)
      expect(initialize_from("null")).to eq(403)
      delete "/mcp", nil, "HTTP_ORIGIN" => "https://evil.example", "HTTP_MCP_SESSION_ID" => "x"
      expect(last_response.status).to eq(403)
    end

    it "accepts listed origins, globally or per server, and :any" do
      RorMcp.configure do |c|
        c.allowed_origins = ["https://App.example.com"]
        c.server :analytics, name: "parity-analytics", stateless: true, allowed_origins: :any
      end
      expect(initialize_from("https://app.example.com")).to eq(200)
      expect(initialize_from("https://other.example")).to eq(403)
      expect(initialize_from("https://other.example", "/mcp/analytics")).to eq(200)
    end

    it "rejects allowed_origins that aren't origins" do
      expect { RorMcp.configure { |c| c.allowed_origins = ["https://app.example.com/mcp"] } }
        .to raise_error(RorMcp::ConfigurationError, /not an origin/)
      expect { RorMcp.configure { |c| c.allowed_origins = ["app.example.com"] } }.to raise_error(RorMcp::ConfigurationError)
    end
  end
end
