# frozen_string_literal: true

require "rack"
require "mcp"
require_relative "ror_mcp/version"
require_relative "ror_mcp/configuration"
require_relative "ror_mcp/session_store"
require_relative "ror_mcp/server"
require_relative "ror_mcp/endpoint"

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
