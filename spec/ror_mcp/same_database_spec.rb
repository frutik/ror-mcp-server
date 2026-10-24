# frozen_string_literal: true

# Two SQLite :memory: databases share adapter and database name, like two
# PostgreSQL hosts with the same database name.
module SameNameDb
  class Record < ActiveRecord::Base
    self.abstract_class = true
  end

  # Lives in its own database, in a table named like ShopDb's.
  class Customer < Record
    self.table_name = "customers"
  end

  # ShopDb's orders, pointing at the other database's customers.
  class Order < ShopDb::Record
    self.table_name = "orders"
    belongs_to :customer, class_name: "SameNameDb::Customer"
  end

  def self.connect!
    return if @connected

    Record.establish_connection(adapter: "sqlite3", database: ":memory:")
    Record.connection.create_table(:customers) { |t| t.string :name }
    Customer.create!(id: 1, name: "Remote customer")
    @connected = true
  end
end

# A join runs on the queried collection's connection, so it is only allowed
# between models that share one (Schema.same_database?).
RSpec.describe "references across databases" do
  before do
    ShopDb.setup!
    SameNameDb.connect!
  end

  after { RorMcp.reset! }

  let!(:remote_customers) do
    define_collection("RemoteCustomers") do
      model SameNameDb::Customer
      collection_name "remote_customer"
      fields :id, :name
    end
  end

  let!(:orders) do
    define_collection("RemoteOrders") do
      model SameNameDb::Order
      collection_name "order"
      fields :id, :customer
    end
  end

  let(:collections) { RorMcp.registry.collections_for(:default) }

  # :parity checks `from` against model names, as django-mcp-server does.
  def lookup(from) = { "$lookup" => { "from" => from, "localField" => "customer", "foreignField" => "_id", "as" => "c" } }

  def rows(pipeline, semantics:)
    RorMcp::Pipeline::Compiler.new(orders, orders.model.all, collections: collections, semantics: semantics)
                              .rows(JSON.parse(JSON.generate(pipeline)))
  end

  it "tells databases apart by connection, not by adapter and database name" do
    expect(SameNameDb::Customer.connection_db_config.database).to eq(ShopDb::Customer.connection_db_config.database) if ShopDb.url.nil?
    expect(RorMcp::Schema.same_database?(SameNameDb::Order, SameNameDb::Customer)).to be(false)
    expect(RorMcp::Schema.same_database?(SameNameDb::Order, ShopDb::Customer)).to be(true)
    ShardDb.setup!
    expect(RorMcp::Schema.same_database?(ShardDb::Event, ShopDb::Customer)).to be(false)
  end

  it "leaves a reference into another database out of the schema" do
    catalog = RorMcp::Pipeline::Catalog.new(orders, collections, semantics: :fixed)
    expect(RorMcp::Schema.json_schema(orders, [], catalog: catalog).dig("$jsonSchema", "properties").keys).to eq(%w[id])
  end

  it "refuses the $lookup instead of reading the queried database's same-named table" do
    # The remote collection publishes one customer; the local customers table must not answer for it.
    expect(RorMcp::Executor.new(collections, semantics: :fixed).call("remote_customer", []).content.first[:text])
      .to eq('[{"id":1,"name":"Remote customer"}]')
    expect { rows([lookup("remote_customer"), { "$project" => { "who" => "$c.name" } }], semantics: :fixed) }
      .to raise_error(RorMcp::Pipeline::QueryError, /Cannot resolve keyword 'customer'/)
    expect { rows([lookup("customer"), { "$project" => { "who" => "$c.name" } }], semantics: :parity) }
      .to raise_error(RorMcp::Pipeline::QueryError,
                      /Order and SameNameDb::Customer are in different databases.*one connection class/)
  end
end
