# frozen_string_literal: true

require "rack"
require "mcp"
require "logger"
require "active_record"
require_relative "ror_mcp/version"
require_relative "ror_mcp/configuration"
require_relative "ror_mcp/session_store"
require_relative "ror_mcp/python_repr"
require_relative "ror_mcp/py_decimal"
require_relative "ror_mcp/registry"
require_relative "ror_mcp/collection"
require_relative "ror_mcp/toolset"
require_relative "ror_mcp/schema"
require_relative "ror_mcp/pipeline/errors"
require_relative "ror_mcp/pipeline/catalog"
require_relative "ror_mcp/pipeline/fields"
require_relative "ror_mcp/pipeline/lookups"
require_relative "ror_mcp/pipeline/match"
require_relative "ror_mcp/pipeline/compiler"
require_relative "ror_mcp/renderers/json"
require_relative "ror_mcp/renderers/csv"
require_relative "ror_mcp/tools/query_tool_text"
require_relative "ror_mcp/tools/query_tool"
require_relative "ror_mcp/envelope"
require_relative "ror_mcp/executor"
require_relative "ror_mcp/server"
require_relative "ror_mcp/endpoint"
require_relative "ror_mcp/inspector"

# Rails port of django-mcp-server. See PLAN.md for the design; components land
# milestone by milestone (PLAN §8).
module RorMcp
  MUTEX = Mutex.new
  private_constant :MUTEX

  class << self
    def configure
      yield configuration
      MUTEX.synchronize { @servers = nil }
      configuration
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def logger
      @logger ||= defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger ? Rails.logger : Logger.new($stderr)
    end

    attr_writer :logger

    # The request being served, for toolsets (django-mcp-server puts it in a contextvar).
    def current_request
      Thread.current[:ror_mcp_request]
    end

    def current_request=(request)
      Thread.current[:ror_mcp_request] = request
    end

    # Every Collection subclass, in definition order.
    def registry
      @registry ||= Registry.new
    end

    # The servers declared in the configuration, built once: each holds its
    # session store, so two copies would lose sessions.
    def servers
      MUTEX.synchronize do
        @servers ||= configuration.servers.transform_values { |server_config| Server.new(server_config, configuration) }
      end
    end

    def server(key)
      key = key.to_sym
      servers[key] || begin
        configuration.server_config(key) # raises ConfigurationError for an undeclared server
        MUTEX.synchronize { @servers = nil } # declared after the servers were built
        servers.fetch(key)
      end
    end

    # Rack app for one server: `mount RorMcp.endpoint(:sales), at: "/mcp/sales"`.
    def endpoint(key = :default)
      Endpoint.new(key)
    end

    # Drops configuration and servers (tests).
    def reset!
      MUTEX.synchronize do
        @configuration = nil
        @servers = nil
      end
    end
  end
end

require_relative "ror_mcp/engine" if defined?(Rails::Engine)
