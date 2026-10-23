# frozen_string_literal: true

require "rack/test"
require_relative "../../spike/transport/spike"

# Pins what the M0 transport spike established about the `mcp` gem (PLAN §10.1).
RSpec.describe "transport spike" do
  include Rack::Test::Methods

  def app = @app ||= TransportSpike.app

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

  describe "initialize (A3, A5)" do
    it "answers plain JSON from a Rack app mounted under a path prefix and issues a session id" do
      rpc("/mcp", "initialize", initialize_params)
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to start_with("application/json")
      expect(last_response.headers["mcp-session-id"]).to match(/\A\h{32}\z/)
      expect(json.dig("result", "serverInfo", "name")).to eq("parity-shop")
      expect(json.dig("result", "instructions")).to start_with("Reference shop server")
    end

    # FastMCP sends the same keys with explicit listChanged/subscribe: false; a stateless SDK transport
    # strips those flags (it cannot deliver notifications). The parity client compares keys only.
    it "advertises the same capability keys as FastMCP" do
      rpc("/mcp", "initialize", initialize_params)
      expect(json.dig("result", "capabilities")).to eq("experimental" => {}, "prompts" => {}, "resources" => {}, "tools" => {})
    end

    it "negotiates the protocol versions current clients send (A7)" do
      %w[2025-03-26 2025-06-18 2025-11-25].each do |version|
        rpc("/mcp", "initialize", initialize_params(version))
        expect(json.dig("result", "protocolVersion")).to eq(version)
      end
    end

    it "answers an unknown protocol version with the newest handshake version" do
      rpc("/mcp", "initialize", initialize_params("2099-01-01"))
      expect(json.dig("result", "protocolVersion")).to eq(MCP::Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION)
    end

    it "does not check the Host header (left to Rails' HostAuthorization)" do
      rpc("/mcp", "initialize", initialize_params, headers: { "Host" => "shop.example.com" })
      expect(last_response.status).to eq(200)
    end
  end

  describe "django-mcp-server session rules in front of a stateless SDK (A4, §1A.2)" do
    it "rejects a non-initialize request without a session with 400" do
      expect(rpc("/mcp", "tools/list").status).to eq(400)
    end

    it "rejects an unknown session with 404" do
      expect(rpc("/mcp", "tools/list", session: "nope").status).to eq(404)
    end

    it "accepts notifications with 202 and requests on a live session with 200" do
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
  end

  describe "tools (A6)" do
    it "lists the tools with their input schemas" do
      rpc("/mcp", "tools/list", session: open_session)
      add = json.dig("result", "tools").find { |t| t["name"] == "add" }
      expect(add["inputSchema"]).to include("type" => "object", "required" => ["a", "b"])
    end

    it "returns text content" do
      expect(call_tool("add", a: 2, b: 5)["result"]).to eq("content" => [{ "type" => "text", "text" => "7" }], "isError" => false)
    end

    it "passes an embedded resource through unchanged" do
      content = call_tool("embedded_resource").dig("result", "content")
      expect(content.last).to eq("type" => "resource", "resource" => {
        "uri" => "resource://query_result/json", "mimeType" => "application/json", "text" => '[{"id":1}]',
      })
    end

    it "reports missing arguments as an isError result, like FastMCP" do
      result = call_tool("add", a: 1)["result"]
      expect(result["isError"]).to be(true)
      expect(result.dig("content", 0, "text")).to eq("Missing required arguments: b")
    end

    # Differences from FastMCP that RorMcp::Toolset has to bridge (FastMCP answers both with isError results).
    it "turns an exception into a JSON-RPC internal error, hiding the message" do
      response = call_tool("explode", reason: "boom")
      expect(response).not_to have_key("result")
      expect(response.dig("error", "code")).to eq(-32603)
      expect(response.to_json).not_to include("boom")
    end

    it "turns an unknown tool into a JSON-RPC invalid-params error" do
      expect(call_tool("does_not_exist").dig("error", "code")).to eq(-32602)
    end

    it "lets a tool return an isError result itself" do
      expect(call_tool("explode_as_tool_error").dig("result", "isError")).to be(true)
    end
  end

  describe "second server: stateless with bearer auth (A36)" do
    let(:auth) { { "Authorization" => "Bearer parity-secret" } }

    it "answers 401 with WWW-Authenticate: Bearer without a valid token" do
      expect(rpc("/mcp/analytics", "initialize", initialize_params).status).to eq(401)
      expect(last_response.headers["www-authenticate"]).to eq("Bearer")
      expect(rpc("/mcp/analytics", "initialize", initialize_params, headers: { "Authorization" => "Bearer x" }).status).to eq(401)
    end

    it "needs no session and issues none" do
      rpc("/mcp/analytics", "initialize", initialize_params, headers: auth)
      expect(last_response.status).to eq(200)
      expect(last_response.headers).not_to have_key("mcp-session-id")
      expect(json.dig("result", "serverInfo", "name")).to eq("parity-analytics")
      expect(rpc("/mcp/analytics", "tools/list", headers: auth).status).to eq(200)
    end

    it "hands the authenticate block's result to tools as server_context[:auth_info]" do
      rpc("/mcp/analytics", "tools/call", { name: "whoami", arguments: {} }, headers: auth)
      expect(json.dig("result", "content", 0, "text")).to eq('{"token":"analytics"}')
    end
  end
end
