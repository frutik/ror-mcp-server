# frozen_string_literal: true

module RorMcp
  class ConfigurationError < StandardError; end

  # Settings from `RorMcp.configure` (PLAN §4.1). Counterpart of django-mcp-server's
  # DJANGO_MCP_* settings.
  class Configuration
    PIPELINE_SEMANTICS = %i[parity fixed].freeze

    # One declared server. `authenticate` is nil to inherit the global block,
    # false to disable authentication, or a callable(request) → context | nil.
    ServerConfig = Struct.new(:key, :name, :instructions, :stateless, :authenticate, keyword_init: true)

    attr_reader :servers, :pipeline_semantics
    attr_accessor :session_store, :instructions_tool

    def initialize
      @servers = {}
      @authenticate = nil
      @session_store = :memory
      @instructions_tool = true
      @pipeline_semantics = :fixed
      default_server
    end

    # django-mcp-server's DJANGO_MCP_GLOBAL_SERVER_CONFIG.
    def default_server(**options)
      server(:default, **options)
    end

    def server(key, name: nil, instructions: nil, stateless: false, authenticate: nil)
      key = key.to_sym
      @servers[key] = ServerConfig.new(
        key: key,
        name: name || (key == :default ? "ror_mcp_server" : key.to_s),
        instructions: instructions,
        stateless: stateless,
        authenticate: authenticate,
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
