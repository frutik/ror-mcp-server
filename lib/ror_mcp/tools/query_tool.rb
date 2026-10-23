# frozen_string_literal: true

require "json"

module RorMcp
  module Tools
    # query_data_collections: one per server that publishes collections, with
    # every collection's schema in its description (django-mcp-server's QueryTool).
    module QueryTool
      NAME = "query_data_collections"

      INPUT_SCHEMA = {
        properties: {
          collection: { type: "string" },
          search_pipeline: { default: [], items: { additionalProperties: true, type: "object" }, type: "array" },
        },
        required: ["collection"],
      }.freeze

      module_function

      def build(collections)
        collections.each_value(&:validate_columns!)
        MCP::Tool.define(name: NAME, description: description(collections), input_schema: INPUT_SCHEMA) do |collection:, search_pipeline: [], server_context: nil|
          context = server_context.respond_to?(:auth_info) ? server_context.auth_info : nil
          # Arguments may arrive with symbol keys; the compiler works on JSON as sent.
          pipeline = JSON.parse(JSON.generate(search_pipeline))
          Executor.new(collections, context: context).call(collection, pipeline)
        end
      end

      def description(collections)
        published = collections.values.map(&:model)
        collections.each_with_object(QueryToolText::PREAMBLE.dup) do |(name, collection), text|
          schema = PythonRepr.dump(Schema.json_schema(collection, published))
          text << "\n### '#{name}' collection\nDocuments conform the following JSON Schema\n```json\n#{schema}\n```\n\n"

          search = Schema.text_search_fields(collection)
          text << if search.empty?
                    "Full text search is not supported on this collection."
                  else
                    "Full text search is supported on the following fields: #{search.join(', ')}."
                  end
          instructions = collection.instructions.to_s
          text << "\n\nExtra instructions for this collection:\n\n#{instructions}\n" unless instructions.empty?
        end
      end
    end
  end
end
