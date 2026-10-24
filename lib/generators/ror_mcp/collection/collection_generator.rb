# frozen_string_literal: true

require "rails/generators"

module RorMcp
  module Generators
    # rails generate ror_mcp:collection Order --fields id number status customer [--server sales] [--model Order]
    class CollectionGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)
      desc "Creates app/mcp/<name>_collection.rb publishing a model as an MCP collection."

      class_option :fields, type: :array, default: [], desc: "Published fields (default: all columns)"
      class_option :server, type: :string, desc: "Server key (default: the default server)"
      class_option :model, type: :string, desc: "Model class (default: NAME)"

      def create_collection
        template "collection.rb.tt", File.join("app/mcp", class_path, "#{file_name}_collection.rb")
      end

      private

      def model_class
        options[:model] || class_name
      end

      def field_list
        options[:fields].empty? ? ":all" : options[:fields].map { |field| ":#{field}" }.join(", ")
      end
    end
  end
end
