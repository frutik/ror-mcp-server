# frozen_string_literal: true

RSpec.describe RorMcp::Tools::QueryTool do
  before { ShopDb.setup! }

  let!(:orders) do
    define_collection("OrderCollection") do
      model ShopDb::Order
      collection_name "order"
      fields :id, :number, :status, :customer
      instructions "Latest order = highest id."

      def scope(context)
        context ? ShopDb::Order.where(customer_id: context[:customer_id]) : ShopDb::Order.all
      end
    end
  end

  let!(:customers) do
    define_collection("CustomerCollection") do
      model ShopDb::Customer
      collection_name "customer"
      fields :id, :name
      output_as_resource true
    end
  end

  let(:collections) { RorMcp.registry.collections_for(:default) }

  def call(collection, pipeline, context: nil)
    RorMcp::Executor.new(collections, context: context).call(collection, JSON.parse(JSON.generate(pipeline))).to_h
  end

  describe ".description" do
    subject(:text) { described_class.description(collections) }

    it "is django-mcp-server's preamble followed by one section per collection" do
      expect(text).to start_with("\nUse this tool to query data available in the server. \n")
      expect(text).to include("## Available collections to query\n\n### 'order' collection\nDocuments conform the following JSON Schema\n```json\n{'description': 'Order(")
      expect(text).to include("'customer': {'bsonType': 'objectId', 'description': 'Reference to Customer', 'ref': 'Customer'}")
      expect(text).to include("```\n\nFull text search is supported on the following fields: number, status.\n\n" \
                              "Extra instructions for this collection:\n\nLatest order = highest id.\n\n### 'customer' collection")
      expect(text).to end_with("Full text search is supported on the following fields: name.")
    end
  end

  describe "query execution" do
    it "returns rows as one JSON text content" do
      result = call("order", [{ "$match" => { "_id" => 1 } }, { "$project" => { "number" => 1 } }])
      expect(result).to eq(content: [{ type: "text", text: '[{"number":"ORD-1"}]' }], isError: false)
    end

    it "finds collections case-insensitively" do
      expect(call("Order", [{ "$match" => { "_id" => 2 } }, { "$project" => { "id" => 1 } }])[:content].first[:text]).to eq('[{"id":2}]')
    end

    it "starts from the collection's scope with the authenticate context" do
      text = call("order", [{ "$project" => { "id" => 1 } }], context: { customer_id: 1 })[:content].first[:text]
      expect(text).to eq('[{"id":3}]')
    end

    it "returns no content for an empty result" do
      expect(call("order", [{ "$match" => { "status" => "nope" } }])).to eq(content: [], isError: false)
    end

    it "attaches results as an embedded resource when asked" do
      content = call("customer", [{ "$match" => { "_id" => 1 } }, { "$project" => { "name" => 1 } }])[:content]
      expect(content).to eq([
        { type: "text", text: "Results attached" },
        { type: "resource", resource: { uri: "resource://query_result/json", mimeType: "application/json", text: '[{"name":"Anna"}]' } },
      ])
      expect(call("customer", [{ "$match" => { "name" => "nobody" } }])[:content]).to eq([{ type: "text", text: "No results found" }])
    end

    it "reports problems as isError results, like FastMCP" do
      expect(call("invoice", [])).to eq(
        content: [{ type: "text", text: "Error executing tool query_data_collections: No such collection, available collections: order, customer" }],
        isError: true,
      )
      expect(call("order", [{ "$match" => { "nope" => 1 } }])[:isError]).to be(true)
    end
  end

  it "is published on the server with the collections, after get_server_instructions" do
    RorMcp.reset!
    expect(RorMcp.server(:default).tools.map(&:name_value)).to eq(%w[get_server_instructions query_data_collections])
  ensure
    RorMcp.reset!
  end
end
