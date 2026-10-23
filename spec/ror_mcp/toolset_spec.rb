# frozen_string_literal: true

RSpec.describe RorMcp::Toolset do
  def define_toolset(const_name, &block)
    klass = Class.new(described_class)
    stub_const(const_name, klass)
    klass.class_eval(&block)
    klass
  end

  let!(:tools) do
    define_toolset("ShopTools") do
      tool :add, description: "Add two integers." do
        param :a, :integer, required: true
        param :b, :integer, required: true
      end
      def add(a:, b:) = a + b

      tool :search, description: "Search." do
        param :query, :string, required: true, desc: "search terms"
        param :brands, [:string]
        param :filters, :object
        param :limit, :integer, default: 20
      end
      def search(query:, brands: nil, filters: nil, limit: 20) = { "query" => query, "brands" => brands, "limit" => limit }

      tool :rows, description: "A list." do
      end
      def rows = [{ "a" => 1 }, "text", 2]

      tool :nothing, description: "Nil."
      def nothing = nil

      tool :whoami, description: "Context and request."
      def whoami = { context: context, path: request&.path }

      tool :explode, description: "Fails."
      def explode = raise(ArgumentError, "boom")

      tool :latest, description: "Serialized.", serialize_with: ->(v) { { "total" => BigDecimal("1398.00"), "at" => v } }
      def latest = Time.utc(2025, 9, 21, 18, 19)
    end
  end

  def call(name, arguments = {}, context: nil)
    tool = ShopTools.tools.fetch(name)
    server_context = Struct.new(:auth_info).new(context)
    ShopTools.call(tool, arguments, server_context).to_h
  end

  def texts(result) = result[:content].map { |c| c[:text] }

  it "describes parameters with the JSON Schema pydantic writes for the Python hints" do
    expect(described_class.input_schema(ShopTools.tools["add"]))
      .to eq(properties: { "a" => { "type" => "integer" }, "b" => { "type" => "integer" } }, required: %w[a b])
    expect(described_class.input_schema(ShopTools.tools["search"])).to eq(
      properties: {
        "query" => { "type" => "string", "description" => "search terms" },
        "brands" => { "items" => { "type" => "string" }, "type" => "array" },
        "filters" => { "additionalProperties" => true, "type" => "object" },
        "limit" => { "type" => "integer", "default" => 20 },
      },
      required: ["query"],
    )
    expect(described_class.input_schema(ShopTools.tools["nothing"])).to eq(properties: {})
  end

  it "converts return values like FastMCP" do
    expect(texts(call("add", { a: 2, b: 5 }))).to eq(["7"])
    expect(texts(call("search", { query: "x" }))).to eq([%({\n  "query": "x",\n  "brands": null,\n  "limit": 20\n})])
    expect(texts(call("rows"))).to eq([%({\n  "a": 1\n}), "text", "2"])
    expect(call("nothing")[:content]).to eq([])
  end

  it "passes only declared arguments and lets method defaults apply" do
    expect(texts(call("search", { "query" => "x", "limit" => 5, "extra" => 1 })).first).to include('"limit": 5')
  end

  it "gives each call a fresh instance with the authenticate context and the request" do
    RorMcp.current_request = Rack::Request.new(Rack::MockRequest.env_for("/mcp"))
    expect(texts(call("whoami", context: { user: 7 }))).to eq([%({\n  "context": {\n    "user": 7\n  },\n  "path": "/mcp"\n})])
  ensure
    RorMcp.current_request = nil
  end

  it "turns exceptions into isError results with FastMCP's wording" do
    expect(call("explode")).to eq(content: [{ type: "text", text: "Error executing tool explode: boom" }], isError: true)
  end

  it "runs serialize_with first; decimals become strings as in DRF/pydantic output" do
    expect(texts(call("latest"))).to eq([%({\n  "total": "1398.0",\n  "at": "2025-09-21T18:19:00Z"\n})])
  end

  it "publishes its tools on its server, after get_server_instructions" do
    RorMcp.reset!
    expect(RorMcp.server(:default).tools.map(&:name_value).first(3)).to eq(%w[get_server_instructions add search])
  ensure
    RorMcp.reset!
  end

  it "rejects a tool name published twice on a server, and tools without a method" do
    define_toolset("OtherTools") do
      tool :add, description: "Again."
      def add = 1
    end
    expect { RorMcp.registry.toolset_tools_for(:default) }.to raise_error(RorMcp::ConfigurationError, /"add" is published twice/)

    define_toolset("Broken") { tool :missing, description: "No method." }
    expect { Broken.validate! }.to raise_error(RorMcp::ConfigurationError, /no method missing/)
  end
end

RSpec.describe RorMcp::Renderers::Csv do
  it "renders like djangorestframework-csv: sorted header, flattened values, Python str(), \\r\\n" do
    rows = [
      { "number" => "ORD-1", "total" => RorMcp::PyDecimal.scaled("499.9", 2), "placed_at" => Time.utc(2024, 11, 26, 12, 23),
        "metadata" => { "channel" => "web", "coupon" => nil }, "ok" => true },
      { "number" => "ORD,2", "total" => RorMcp::PyDecimal.scaled("2386.9", 2), "placed_at" => Time.utc(2024, 1, 1, 0, 0, 0.5r),
        "metadata" => nil, "ok" => false },
    ]
    expect(described_class.render(rows)).to eq(
      "metadata,metadata.channel,metadata.coupon,number,ok,placed_at,total\r\n" \
      ",web,,ORD-1,True,2024-11-26 12:23:00+00:00,499.90\r\n" \
      ",,,\"ORD,2\",False,2024-01-01 00:00:00.500000+00:00,2386.90\r\n",
    )
  end
end

RSpec.describe RorMcp::PyDecimal do
  it "keeps the column's scale, like a quantized Django Decimal" do
    expect(described_class.scaled("899", 2).to_s).to eq("899.00")
    expect(described_class.scaled(BigDecimal("1.005"), 2).to_s).to eq("1.00") # half-even, like Decimal.quantize
    expect(described_class.scaled("7", 0).to_s).to eq("7")
  end

  it "renders averages with 15 significant digits" do
    expect(described_class.significant(1016.1633333333334).to_s).to eq("1016.16333333333")
    expect(described_class.significant(2388.95).to_s).to eq("2388.95000000000")
  end

  it "compares as a number and renders as a float in JSON" do
    expect(described_class.scaled("499.9", 2)).to eq(BigDecimal("499.9"))
    expect(RorMcp::Renderers::Json.render(described_class.scaled("899", 2))).to eq("899.0")
  end
end
