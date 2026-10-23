# frozen_string_literal: true

require "securerandom"

module RorMcp
  # Stores which Mcp-Session-Id values are live. Like django-mcp-server's use of
  # Django sessions, a session holds nothing MCP-specific: only its existence matters.
  #
  # A custom store is any object with #create (→ new id), #exists?(id) and #delete(id).
  module SessionStore
    def self.build(setting)
      case setting
      when :memory then Memory.new
      when :cache then Cache.new
      when Symbol then raise ConfigurationError, "Unknown session_store #{setting.inspect}: use :memory, :cache or a store object"
      else setting
      end
    end

    def self.generate_id
      SecureRandom.hex(16)
    end
  end
end

require_relative "session_store/memory"
require_relative "session_store/cache"
