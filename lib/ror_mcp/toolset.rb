# frozen_string_literal: true

module RorMcp
  # Publishes Ruby methods as MCP tools (django-mcp-server's MCPToolset).
  # Ruby has no type hints, so each tool declares its parameters:
  #
  #   class CatalogTools < RorMcp::Toolset
  #     tool :search, description: "Search the catalog" do
  #       param :query, :string, required: true
  #       param :limit, :integer, default: 20
  #     end
  #
  #     def search(query:, limit: 20) = Product.search(query).limit(limit)
  #   end
  #
  # Each call gets a new instance with `context` (from authenticate) and
  # `request`. The return value becomes content the way FastMCP converts it;
  # an exception becomes an isError result.
  class Toolset
    Tool = Struct.new(:name, :description, :params, :writes, :serialize_with, keyword_init: true)
    Param = Struct.new(:name, :type, :required, :default, :desc, keyword_init: true)

    # JSON Schema of a parameter type, as pydantic writes it for the Python hint.
    TYPES = {
      string: { "type" => "string" }, integer: { "type" => "integer" }, number: { "type" => "number" },
      boolean: { "type" => "boolean" }, object: { "additionalProperties" => true, "type" => "object" },
    }.freeze

    # The `tool ... do … end` block.
    class ParamBuilder
      attr_reader :params

      def initialize
        @params = []
      end

      def param(name, type, required: false, default: nil, desc: nil)
        @params << Param.new(name: name.to_s, type: type, required: required, default: default, desc: desc)
      end
    end

    class << self
      def inherited(subclass)
        super
        RorMcp.registry.track_toolset(subclass)
      end

      def server(key = nil)
        key.nil? ? (setting(:server) || :default) : (@server = key.to_sym)
      end
      alias server_key server

      # Declares a tool backed by the instance method of the same name.
      # `writes: true` marks a tool that changes data (it runs outside the
      # read-only envelope, PLAN M6). `serialize_with:` shapes the return value
      # first: a callable, a Blueprinter-style class (render_as_hash) or a
      # serializer class (new(value).as_json).
      def tool(name, description:, writes: false, serialize_with: nil, &block)
        builder = ParamBuilder.new
        builder.instance_eval(&block) if block
        @tools = tools.merge(name.to_s => Tool.new(name: name.to_s, description: description, params: builder.params,
                                                   writes: writes, serialize_with: serialize_with))
      end

      def tools
        setting(:tools) || {}
      end

      def abstract!
        @abstract = true
      end

      def abstract?
        @abstract == true
      end

      def published?
        !abstract? && !name.nil? && !tools.empty?
      end

      def validate!
        tools.each_key do |tool_name|
          next if method_defined?(tool_name)

          raise ConfigurationError, "#{name} declares tool #{tool_name.inspect} but has no method #{tool_name}"
        end
        true
      end

      def mcp_tools
        tools.values.map { |tool| build(tool) }
      end

      def input_schema(tool)
        properties = tool.params.to_h do |param|
          schema = schema_for(param.type)
          schema = schema.merge("default" => param.default) unless param.default.nil?
          schema = schema.merge("description" => param.desc) if param.desc
          [param.name, schema]
        end
        required = tool.params.select(&:required).map(&:name)
        { properties: properties }.merge(required.empty? ? {} : { required: required })
      end

      private

      def build(tool)
        toolset = self
        MCP::Tool.define(name: tool.name, description: tool.description, input_schema: input_schema(tool)) do |server_context: nil, **arguments|
          toolset.call(tool, arguments, server_context)
        end
      end

      def schema_for(type)
        return { "items" => schema_for(type.first), "type" => "array" } if type.is_a?(Array)

        TYPES.fetch(type.to_sym) { raise ConfigurationError, "Unknown parameter type #{type.inspect}" }
      end

      def setting(name)
        ivar = :"@#{name}"
        return instance_variable_get(ivar) if instance_variable_defined?(ivar)

        superclass.send(:setting, name) if superclass < Toolset
      end
    end

    # Runs one call: new instance, declared arguments only, FastMCP's
    # conversion. Tools not declared `writes: true` run in the read-only envelope.
    def self.call(tool, arguments, server_context)
      Instrumentation.instrument("tool.ror_mcp", server: server_key, tool: tool.name) do |payload|
        response = run(tool, arguments, server_context)
        payload[:error] = response.content.first[:text] if response.error?
        response
      end
    end

    def self.run(tool, arguments, server_context)
      context = server_context.respond_to?(:auth_info) ? server_context.auth_info : nil
      instance = new(context: context, request: RorMcp.current_request)
      names = tool.params.map { |p| p.name.to_sym }
      invoke = lambda do
        value = instance.public_send(tool.name, **arguments.transform_keys(&:to_sym).slice(*names))
        value = value.to_a if defined?(ActiveRecord::Relation) && value.is_a?(ActiveRecord::Relation)
        value = serialize(tool.serialize_with, value) if tool.serialize_with
        value.is_a?(MCP::Tool::Response) ? value : MCP::Tool::Response.new(Tools::Content.from(value))
      end
      tool.writes ? invoke.call : Envelope.read_only(&invoke)
    rescue StandardError => e
      MCP::Tool::Response.new([{ type: "text", text: "Error executing tool #{tool.name}: #{e.message}" }], error: true)
    end

    def self.serialize(serializer, value)
      return serializer.call(value) if serializer.respond_to?(:call)
      return serializer.render_as_hash(value) if serializer.respond_to?(:render_as_hash)

      serializer.new(value).as_json
    end

    attr_reader :context, :request

    def initialize(context: nil, request: nil)
      @context = context
      @request = request
    end
  end

  module Tools
    # FastMCP's _convert_to_content: strings as they are, lists one content per
    # element, anything else as JSON with indent 2; nil gives no content.
    module Content
      module_function

      def from(value)
        case value
        when nil then []
        when Array then value.flat_map { |item| from(item) }
        when String then [text(value)]
        else
          value = value.as_json if !json_native?(value) && value.respond_to?(:as_json)
          [text(Renderers::Json.pretty(value))]
        end
      end

      def json_native?(value)
        [Hash, Integer, Float, BigDecimal, PyDecimal, Time, DateTime, Date, TrueClass, FalseClass, Symbol].any? { |k| value.is_a?(k) }
      end

      def text(value)
        { type: "text", text: value }
      end
    end
  end
end
