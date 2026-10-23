# frozen_string_literal: true

module RorMcp
  # Runs one query_data_collections call (django-mcp-server's _QueryExecutor):
  # find the collection, start from its scope, run the pipeline inside the
  # safety envelope, render.
  class Executor
    def initialize(collections, context: nil, server: nil, semantics: RorMcp.configuration.pipeline_semantics)
      @collections = collections.transform_keys(&:downcase)
      @context = context
      @server = server
      @semantics = semantics
    end

    # → MCP::Tool::Response. Problems with the request come back as isError
    # results with the reason, as FastMCP reports tool exceptions.
    def call(collection_name, pipeline)
      Instrumentation.instrument("query.ror_mcp", server: @server, collection: collection_name.to_s, pipeline: pipeline) do |payload|
        response = run(collection_name, pipeline)
        payload[:rows] = @row_count
        payload[:error] = response.content.first[:text] if response.error?
        response
      end
    end

    private

    def run(collection_name, pipeline)
      collection = @collections[collection_name.to_s.downcase]
      unless collection
        raise Pipeline::QueryError, "No such collection, available collections: #{@collections.keys.join(', ')}"
      end

      pipeline, routing = Routing.extract(collection, pipeline)
      connection = collection.connection_options.merge(routing)
      rows = Envelope.read_only(collection.model, role: connection[:role] || RorMcp.configuration.read_role,
                                                  shard: connection[:shard]) do
        relation = collection.new(@context).scope(@context)
        Adapters.prepare(relation.connection)
        Pipeline::Compiler.new(collection, relation, collections: @collections, semantics: @semantics, context: @context)
                          .rows(pipeline)
      end
      @row_count = rows.size
      respond(collection, rows)
    rescue Pipeline::QueryError, ActiveRecord::ActiveRecordError, ArgumentError, TypeError => e
      MCP::Tool::Response.new([{ type: "text", text: "Error executing tool #{Tools::QueryTool::NAME}: #{e.message}" }],
                              error: true)
    end

    def respond(collection, rows)
      if rows.empty?
        return MCP::Tool::Response.new([text("No results found")]) if collection.output_as_resource
        # django-mcp-server returns [] unrendered (no content); :fixed renders it.
        return MCP::Tool::Response.new(@semantics == :fixed ? [text(Renderers.for(collection.output_format).render([]))] : [])
      end

      renderer = Renderers.for(collection.output_format)
      body = renderer.render(rows)
      return MCP::Tool::Response.new([text(body)]) unless collection.output_as_resource

      MCP::Tool::Response.new([
        text("Results attached"),
        { type: "resource", resource: { uri: "resource://query_result/#{renderer::FORMAT}",
                                        mimeType: renderer::MEDIA_TYPE, text: body } },
      ])
    end

    def text(value)
      { type: "text", text: value }
    end
  end

  # A collection's routing_field: the equality in $match that picks the shard.
  module Routing
    module_function

    # → [pipeline without the routing condition, connected_to options]
    def extract(collection, pipeline)
      routing = collection.routing_field
      return [pipeline, {}] unless routing && pipeline.is_a?(Array)

      values = []
      stripped = pipeline.map do |stage|
        match = stage.is_a?(Hash) ? stage["$match"] : nil
        next stage unless match.is_a?(Hash) && match.key?(routing.name)

        values << equality(routing, match[routing.name])
        stage.merge("$match" => match.except(routing.name))
      end

      if values.empty?
        raise Pipeline::QueryError, "'#{routing.name}' is a routing field and is required: add {\"#{routing.name}\": \"<value>\"} " \
                                    "to the first $match"
      end
      if values.uniq.size > 1
        raise Pipeline::QueryError, "'#{routing.name}' must have one value per query, got #{values.uniq.map(&:inspect).join(', ')}"
      end

      options = routing.to.call(values.first)
      raise Pipeline::QueryError, "No database for #{routing.name} #{values.first.inspect}" unless options.is_a?(Hash)

      [stripped, options.transform_keys(&:to_sym)]
    end

    def equality(routing, condition)
      value = condition.is_a?(Hash) && condition.keys == ["$eq"] ? condition["$eq"] : condition
      if value.nil? || value.is_a?(Hash) || value.is_a?(Array)
        raise Pipeline::QueryError, "'#{routing.name}' is a routing field: compare it with one value " \
                                    "({\"#{routing.name}\": \"<value>\"}), not #{condition.inspect}"
      end
      value
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
