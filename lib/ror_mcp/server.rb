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
      @configuration = configuration
      @tools = []
      @mutex = Mutex.new
    end

    def stateless?
      @stateless
    end

    # Registers an extra, hand-built MCP::Tool (toolsets and collections register themselves).
    def add_tool(tool)
      @mutex.synchronize do
        @tools << tool
        @mcp_server = @transport = nil
      end
    end

    # In django-mcp-server's order: get_server_instructions, toolset tools, query_data_collections.
    def tools
      list = @instructions_tool ? [instructions_tool, *@tools] : @tools.dup
      list.concat(RorMcp.registry.toolset_tools_for(@key))
      collections = RorMcp.registry.collections_for(@key)
      unless collections.empty?
        query_tool = Tools::QueryTool.build(collections, server: @key)
        check_description_budget(query_tool.description_value)
        warn_parity_fields(collections)
        list << query_tool
      end
      list
    end

    # Rebuilt when collections change (code reload in development).
    def mcp_server
      @mutex.synchronize do
        if @mcp_server.nil? || @registry_version != RorMcp.registry.version
          @registry_version = RorMcp.registry.version
          @mcp_server = build_mcp_server
          @transport = nil
        end
        @mcp_server
      end
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

    # Clients truncate long tool descriptions and silently lose collections (PLAN §3).
    def check_description_budget(description)
      budget = @configuration.description_budget
      return if budget.nil? || description.length <= budget

      message = "MCP server #{@key.inspect}: the query_data_collections description is #{description.length} characters, " \
                "over the description_budget of #{budget}. Narrow `fields` or move collections to another server."
      raise ConfigurationError, message if @configuration.description_budget_mode == :raise

      RorMcp.logger.warn(message)
    end

    # Under :parity, `fields` only shapes the schema; queries without $project still return every column.
    def warn_parity_fields(collections)
      return unless @configuration.pipeline_semantics == :parity

      narrowed = collections.values.reject { |c| c.fields == :all }.map(&:name)
      return if narrowed.empty?

      RorMcp.logger.warn("MCP server #{@key.inspect} uses :parity semantics: #{narrowed.join(', ')} limit `fields`, " \
                         "but a pipeline without $project still returns every column (as in django-mcp-server).")
    end

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
      MCP::Tool.define(name: INSTRUCTIONS_TOOL_NAME, description: INSTRUCTIONS_TOOL_DESCRIPTION,
                       input_schema: { properties: {} }) do
        MCP::Tool::Response.new([{ type: "text", text: text }])
      end
    end
  end
end
