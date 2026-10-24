# frozen_string_literal: true

require "rails/generators"

module RorMcp
  module Generators
    # rails generate ror_mcp:install
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      desc "Creates config/initializers/ror_mcp.rb, mounts the default MCP server at /mcp and creates app/mcp/."

      def create_initializer
        template "initializer.rb.tt", "config/initializers/ror_mcp.rb"
      end

      def mount_engine
        route 'mount RorMcp::Engine, at: "/mcp"'
      end

      def create_mcp_directory
        create_file "app/mcp/.keep", ""
      end

      private

      def server_name
        app = defined?(Rails.application) && Rails.application ? Rails.application.class.module_parent_name : "app"
        app.to_s.underscore.dasherize
      end
    end
  end
end
