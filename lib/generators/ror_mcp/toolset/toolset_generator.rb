# frozen_string_literal: true

require "rails/generators"

module RorMcp
  module Generators
    # rails generate ror_mcp:toolset CatalogSearch [--server sales]
    class ToolsetGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)
      desc "Creates app/mcp/<name>_tools.rb publishing Ruby methods as MCP tools."

      class_option :server, type: :string, desc: "Server key (default: the default server)"

      def create_toolset
        template "toolset.rb.tt", File.join("app/mcp", class_path, "#{file_name}_tools.rb")
      end
    end
  end
end
