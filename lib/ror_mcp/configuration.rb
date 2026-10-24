# frozen_string_literal: true

module RorMcp
  class ConfigurationError < StandardError; end

  # Settings from `RorMcp.configure` (PLAN §4.1). Counterpart of django-mcp-server's
  # DJANGO_MCP_* settings.
  class Configuration
    PIPELINE_SEMANTICS = %i[parity fixed].freeze

    # One declared server. `authenticate` is nil to inherit the global block,
    # false to disable authentication, or a callable(request) → context | nil.
    # `allowed_origins` is nil to inherit the global list.
    ServerConfig = Struct.new(:key, :name, :instructions, :stateless, :authenticate, :allowed_origins, keyword_init: true)

    DESCRIPTION_BUDGET_MODES = %i[warn raise].freeze

    attr_reader :servers, :pipeline_semantics, :description_budget_mode, :query_subscribers, :tool_subscribers,
                # Browser origins besides the server's own that may call it ("https://app.example.com"),
                # or :any. Requests without an Origin header (non-browser clients) always pass.
                :allowed_origins
    attr_accessor :session_store, :instructions_tool,
                  # Safety envelope (PLAN §5), both semantics:
                  :read_role,          # run queries under connected_to(role:), e.g. :reading for a replica
                  :statement_timeout,  # seconds (Numeric or ActiveSupport::Duration); PostgreSQL and MySQL
                  # :fixed semantics only:
                  :default_limit,      # $limit applied when a pipeline has none
                  :max_limit,          # upper bound on $limit (collections can lower it with max_limit)
                  # Characters of a server's query_data_collections description; nil = no check.
                  :description_budget

    def initialize
      @servers = {}
      @authenticate = nil
      @session_store = :memory
      @instructions_tool = true
      @pipeline_semantics = :fixed
      @read_role = nil
      @statement_timeout = nil
      @default_limit = 100
      @max_limit = 1000
      @description_budget = nil
      @description_budget_mode = :warn
      @query_subscribers = []
      @tool_subscribers = []
      @allowed_origins = []
      default_server
    end

    def allowed_origins=(origins)
      @allowed_origins = Configuration.origins(origins)
    end

    # :any, or origins normalized for comparison ("scheme://host[:port]", lowercase).
    def self.origins(origins)
      return :any if origins == :any

      Array(origins).map do |origin|
        normalized = origin.to_s.downcase.chomp("/")
        unless normalized == "null" || normalized.match?(%r{\Ahttps?://[^/?#\s]+\z})
          raise ConfigurationError, "allowed_origins: #{origin.inspect} is not an origin (scheme://host[:port], no path), :any or \"null\""
        end

        normalized
      end
    end

    def description_budget_mode=(mode)
      mode = mode.to_sym
      raise ConfigurationError, "description_budget_mode must be :warn or :raise" unless DESCRIPTION_BUDGET_MODES.include?(mode)

      @description_budget_mode = mode
    end

    # Called with a RorMcp::Instrumentation::Event after every query_data_collections call.
    def on_query(&block)
      @query_subscribers << block
    end

    # Called with a RorMcp::Instrumentation::Event after every toolset tool call.
    def on_tool(&block)
      @tool_subscribers << block
    end

    # django-mcp-server's DJANGO_MCP_GLOBAL_SERVER_CONFIG.
    def default_server(**options)
      server(:default, **options)
    end

    def server(key, name: nil, instructions: nil, stateless: false, authenticate: nil, allowed_origins: nil)
      key = key.to_sym
      @servers[key] = ServerConfig.new(
        key: key,
        name: name || (key == :default ? "ror_mcp_server" : key.to_s),
        instructions: instructions,
        stateless: stateless,
        authenticate: authenticate,
        allowed_origins: allowed_origins.nil? ? nil : Configuration.origins(allowed_origins),
      )
    end

    # Global authentication: a block receiving the request and returning a context
    # (passed to collections and tools) or nil, which answers 401.
    def authenticate(&block)
      @authenticate = block if block
      @authenticate
    end

    def pipeline_semantics=(value)
      value = value.to_sym
      unless PIPELINE_SEMANTICS.include?(value)
        raise ConfigurationError, "pipeline_semantics must be one of #{PIPELINE_SEMANTICS.join(', ')}, got #{value.inspect}"
      end

      @pipeline_semantics = value
    end

    def server_config(key)
      @servers.fetch(key.to_sym) do
        raise ConfigurationError, "Unknown MCP server #{key.inspect}. Declared servers: #{@servers.keys.join(', ')}"
      end
    end

    def allowed_origins_for(server_config)
      server_config.allowed_origins.nil? ? @allowed_origins : server_config.allowed_origins
    end

    # The authenticator a server uses after applying its own override.
    def authenticator_for(server_config)
      case server_config.authenticate
      when nil then @authenticate
      when false then nil
      else server_config.authenticate
      end
    end
  end
end
