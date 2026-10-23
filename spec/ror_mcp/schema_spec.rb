# frozen_string_literal: true

RSpec.describe RorMcp::Schema do
  before { ShopDb.setup! }

  let!(:customers) do
    define_collection("CustomerCollection") do
      model ShopDb::Customer
      collection_name "customer"
      fields :id, :name, :country, :active, :signed_up_on
      description "A person or company that places orders."
      choice_labels :country, "NL" => "Netherlands", "BE" => "Belgium"
    end
  end

  let!(:orders) do
    define_collection("OrderCollection") do
      model ShopDb::Order
      collection_name "order"
      fields :all
      exclude_fields :metadata
      describe :billing_identity, "Customer billed for the order"
    end
  end

  it "builds django-mcp-server's $jsonSchema, key order included" do
    schema = described_class.json_schema(orders)
    expect(RorMcp::PythonRepr.dump(schema)).to eq(
      "{'description': 'Order(id, number, customer, billing_identity, status, total, placed_at, metadata)', " \
      "'$jsonSchema': {'bsonType': 'object', 'properties': {" \
      "'id': {'description': 'Primary unique identifier for this model', 'bsonType': 'int'}, " \
      "'number': {'bsonType': 'string'}, " \
      "'customer': {'bsonType': 'objectId', 'description': 'Reference to Customer', 'ref': 'Customer'}, " \
      "'billing_identity': {'bsonType': 'objectId', 'description': 'Reference to Customer: Customer billed for the order', 'ref': 'Customer'}, " \
      "'status': {'bsonType': 'string', 'enum': ['pending', 'paid', 'cancelled'], " \
      "'description': \"Choices: 'pending' = Pending, 'paid' = Paid, 'cancelled' = Cancelled\"}, " \
      "'total': {'bsonType': 'double'}, 'placed_at': {'bsonType': 'date'}}, " \
      "'required': ['number', 'customer', 'status', 'total', 'placed_at']}}",
    )
  end

  it "uses choice labels and the collection description" do
    schema = described_class.json_schema(customers)
    expect(schema["description"]).to eq("A person or company that places orders.")
    expect(schema.dig("$jsonSchema", "properties", "country"))
      .to eq("bsonType" => "string", "enum" => %w[NL BE], "description" => "Choices: 'NL' = Netherlands, 'BE' = Belgium")
    expect(schema.dig("$jsonSchema", "required")).to eq(%w[name country active signed_up_on])
  end

  it "drops references to models not published on the same server (exact class, as in Django)" do
    define_collection("ProductCollection") do
      model ShopDb::Product
      fields :all
      describe :sku, "Stock keeping unit"
    end
    properties = described_class.json_schema(ProductCollection).dig("$jsonSchema", "properties")
    expect(properties.keys).to eq(%w[sku name description price specs])
    expect(properties["sku"]).to eq("description" => "Stock keeping unit", "bsonType" => "string")
    expect(properties["specs"]).to eq("bsonType" => "object")
  end

  it "treats an empty-string default as Django's blank=True" do
    define_collection("ProductCollection") do
      model ShopDb::Product
      fields :all
    end
    expect(described_class.json_schema(ProductCollection).dig("$jsonSchema", "required")).to eq(%w[sku name price])
  end

  it "defaults search fields to string and text columns within fields" do
    expect(described_class.text_search_fields(customers)).to eq(%w[name country])
    expect(described_class.text_search_fields(orders)).to eq(%w[number status])
  end
end

RSpec.describe RorMcp::Registry do
  it "keys collections by server and name, not class name" do
    define_collection("Shop::OrderCollection") { model Class.new; collection_name "order"; fields :all }
    define_collection("Reports::OrderCollection") { server :reports; model Class.new; collection_name "order"; fields :all }
    expect(RorMcp.registry.collections_for(:default).keys).to eq(["order"])
    expect(RorMcp.registry.collections_for(:reports).keys).to eq(["order"])
  end

  it "rejects two collections with one name on a server" do
    define_collection("A") { model Class.new; collection_name "order"; fields :all }
    define_collection("B") { model Class.new; collection_name "order"; fields :all }
    expect { RorMcp.registry.collections_for(:default) }.to raise_error(RorMcp::ConfigurationError, /"order" is published twice.*A and B/)
  end

  it "skips abstract bases and inherits their settings" do
    define_collection("Base") { abstract!; server :reports; fields :all }
    child = Class.new(Base)
    stub_const("BaseChild", child)
    child.model(Class.new)
    child.collection_name "child"
    expect(RorMcp.registry.collections_for(:reports).keys).to eq(["child"])
    expect(child.fields).to eq(:all)
  end

  it "requires fields at boot" do
    define_collection("NoFields") { model Class.new; collection_name "x" }
    expect { RorMcp.registry.validate! }.to raise_error(RorMcp::ConfigurationError, /`fields` is required/)
  end

  it "reports unknown field names against the model's columns" do
    ShopDb.setup!
    define_collection("Typo") { model ShopDb::Customer; fields :name, :emial }
    expect { Typo.validate_columns! }.to raise_error(RorMcp::ConfigurationError, /fields emial not found.*Available: id, name/)
  end
end
