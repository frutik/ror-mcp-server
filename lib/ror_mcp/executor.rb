# frozen_string_literal: true

module RorMcp
  # Runs one query_data_collections call (django-mcp-server's _QueryExecutor):
  # find the collection, start from its scope, run the pipeline, render.
  class Executor
    def initialize(collections, context: nil)
      @collections = collections.transform_keys(&:downcase)
      @context = context
    end

    # → MCP::Tool::Response. Problems with the request come back as isError
    # results with the reason, as FastMCP reports tool exceptions.
    def call(collection_name, pipeline)
      collection = @collections[collection_name.to_s.downcase]
      unless collection
        raise Pipeline::QueryError, "No such collection, available collections: #{@collections.keys.join(', ')}"
      end

      relation = collection.new(@context).scope(@context)
      Adapters.prepare(relation.connection)
      published = @collections.values.map(&:model)
      rows = Pipeline::Compiler.new(collection, relation, published_models: published).rows(pipeline)
      respond(collection, rows)
    rescue Pipeline::QueryError, ActiveRecord::ActiveRecordError, ArgumentError, TypeError => e
      MCP::Tool::Response.new([{ type: "text", text: "Error executing tool #{Tools::QueryTool::NAME}: #{e.message}" }],
                              error: true)
    end

    private

    def respond(collection, rows)
      # An empty result is returned as [] content, unrendered (django-mcp-server quirk).
      if rows.empty?
        return MCP::Tool::Response.new(collection.output_as_resource ? [text("No results found")] : [])
      end

      raise Pipeline::NotYetSupported.new("output_format #{collection.output_format.inspect}", "M5") unless collection.output_format == :json

      body = Renderers::Json.render(rows)
      return MCP::Tool::Response.new([text(body)]) unless collection.output_as_resource

      MCP::Tool::Response.new([
        text("Results attached"),
        { type: "resource", resource: { uri: "resource://query_result/#{Renderers::Json::FORMAT}",
                                        mimeType: Renderers::Json::MEDIA_TYPE, text: body } },
      ])
    end

    def text(value)
      { type: "text", text: value }
    end
  end

  # Database specifics the compiler relies on.
  module Adapters
    module_function

    # SQLite has no REGEXP function unless the application defines one; Django
    # registers re.search-based one. Defined once per raw connection.
    def prepare(connection)
      return unless connection.adapter_name.match?(/sqlite/i)

      raw = connection.raw_connection
      return if raw.instance_variable_get(:@ror_mcp_regexp)

      raw.create_function("regexp", 2) do |func, pattern, value|
        func.result = !value.nil? && Regexp.new(pattern.to_s).match?(value.to_s) ? 1 : 0
      end
      raw.instance_variable_set(:@ror_mcp_regexp, true)
    end
  end
end
