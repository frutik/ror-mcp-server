# frozen_string_literal: true

module RorMcp
  # One MCP server (django-mcp-server's DjangoMCP): name, instructions, tools, and
  # the SDK objects that serve them. Built from a Configuration::ServerConfig.
  class Server
    # What FastMCP advertises. The stateless SDK transport drops the
    # listChanged/subscribe flags FastMCP adds, so only the keys match.
    CAPABILITIES = {
      experimental: {},
      prompts: { listChanged: false },
      resources: { subscribe: false, listChanged: false },
      tools: { listChanged: false },
    }.freeze

    INSTRUCTIONS_TOOL_NAME = "get_server_instructions"
    INSTRUCTIONS_TOOL_DESCRIPTION = "Return MCP server instructions (if any). Always call first."

    attr_reader :key, :name, :instructions, :authenticator, :sessions

    def initialize(server_config, configuration)
      @key = server_config.key
      @name = server_config.name
      @instructions = server_config.instructions
      @stateless = server_config.stateless
      @authenticator = configuration.authenticator_for(server_config)
      @sessions = SessionStore.build(configuration.session_store) unless @stateless
      @instructions_tool = configuration.instructions_tool
      @tools = []
      @mutex = Mutex.new
    end

    def stateless?
      @stateless
    end

    # Registers an MCP::Tool (collections and toolsets add theirs in later milestones).
    def add_tool(tool)
      @mutex.synchronize do
        @tools << tool
        @mcp_server = @transport = nil
      end
    end

    def tools
      @instructions_tool ? [instructions_tool, *@tools] : @tools.dup
    end

    def mcp_server
      @mutex.synchronize { @mcp_server ||= build_mcp_server }
    end

    # The SDK always runs stateless with JSON responses, as django-mcp-server runs
    # the Python SDK: Mcp-Session-Id handling lives in RorMcp::Endpoint. Host and
    # Origin checks are left to Rails (config.hosts): the SDK's DNS-rebinding guard
    # only accepts loopback Host headers.
    def transport
      server = mcp_server
      @mutex.synchronize do
        @transport ||= MCP::Server::Transports::StreamableHTTPTransport.new(
          server, stateless: true, enable_json_response: true, dns_rebinding_protection: false,
        ).tap { |transport| server.transport = transport }
      end
    end

    private

    def build_mcp_server
      MCP::Server.new(
        name: @name,
        version: RorMcp::VERSION,
        instructions: @instructions,
        capabilities: CAPABILITIES,
        tools: tools,
      )
    end

    def instructions_tool
      text = @instructions.to_s
      MCP::Tool.define(name: INSTRUCTIONS_TOOL_NAME, description: INSTRUCTIONS_TOOL_DESCRIPTION) do
        MCP::Tool::Response.new([{ type: "text", text: text }])
      end
    end
  end
end
