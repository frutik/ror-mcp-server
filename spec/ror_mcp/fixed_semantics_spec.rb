# frozen_string_literal: true

# `:fixed` semantics (PLAN §1B): one example per corrected django-mcp-server
# behaviour, then the safety envelope, routing, multi-database rules,
# description budget and instrumentation (PLAN §3, M6).
RSpec.describe "fixed semantics" do
  before do
    ShopDb.setup!
    RorMcp.configuration.pipeline_semantics = :fixed
  end

  after { RorMcp.reset! }

  let!(:orders) do
    define_collection("OrderCollection") do
      model ShopDb::Order
      collection_name "order"
      fields :id, :number, :status, :total, :customer
    end
  end

  let!(:customers) do
    define_collection("CustomerCollection") do
      model ShopDb::Customer
      collection_name "customer"
      fields :id, :name, :country

      def scope(_context) = ShopDb::Customer.where(active: true)
    end
  end

  let(:collections) { RorMcp.registry.collections_for(:default) }

  def rows(pipeline, collection = orders)
    relation = collection.new.scope(nil)
    RorMcp::Pipeline::Compiler.new(collection, relation, collections: collections, semantics: :fixed)
                              .rows(JSON.parse(JSON.generate(pipeline)))
  end

  def ids(pipeline, collection = orders)
    rows(pipeline + [{ "$project" => { "id" => 1 } }], collection).map { |r| r["id"] }
  end

  def lookup(local = "customer", from: "customer", as: "c")
    { "$lookup" => { "from" => from, "localField" => local, "foreignField" => "_id", "as" => as } }
  end

  describe "the field whitelist" do
    it "returns only `fields` without $project" do
      expect(rows([{ "$match" => { "_id" => 1 } }])).to eq([{ "id" => 1, "number" => "ORD-1", "status" => "cancelled",
                                                              "total" => BigDecimal("499.9"), "customer_id" => 2 }])
    end

    it "refuses fields outside the whitelist in every stage" do
      expect { rows([{ "$match" => { "metadata" => nil } }]) }.to raise_error(/Cannot resolve keyword 'metadata'.*Choices are: customer, customer_id, id, number, status, total$/)
      expect { rows([{ "$sort" => { "placed_at" => 1 } }]) }.to raise_error(/'placed_at'/)
      expect { rows([{ "$project" => { "x" => "$billing_identity" } }]) }.to raise_error(/'billing_identity'/)
    end

    it "limits alias.field to the target collection's fields" do
      expect { rows([lookup, { "$project" => { "n" => "$c.notes" } }]) }.to raise_error(/Cannot resolve keyword 'notes'/)
    end
  end

  describe "$lookup" do
    it "checks `from` against the reference's collection" do
      define_collection("ProductCollection") { model ShopDb::Product; collection_name "product"; fields :sku }
      expect { rows([lookup(from: "product")]) }.to raise_error(/points at Customer, not at the 'product' collection. Use "from": "customer"/)
      expect { rows([lookup(from: "nope")]) }.to raise_error(/no such collection.*order, customer/)
    end

    it "accepts the association name or the foreign key, without mangling _id" do
      define_collection("BilledOrders") do
        model ShopDb::Order
        collection_name "billed"
        fields :id, :billing_identity
      end
      result = rows([lookup("billing_identity", as: "b"), { "$match" => { "b.name" => "Anna" } },
                     { "$project" => { "id" => 1, "who" => "$b.name" } }], BilledOrders)
      expect(result).to eq([{ "id" => 2, "who" => "Anna" }])
      expect(rows([lookup("customer_id"), { "$match" => { "_id" => 3 } }, { "$project" => { "who" => "$c.name" } }])).to eq([{ "who" => "Anna" }])
    end

    it "applies the target collection's scope to the join" do
      # Order 4 belongs to Gijs, who is inactive: the customer collection does not publish him.
      result = rows([lookup, { "$match" => { "_id" => 4 } }, { "$project" => { "id" => 1, "who" => "$c.name" } }])
      expect(result).to eq([{ "id" => 4, "who" => nil }])
      expect(rows([lookup, { "$match" => { "c.name" => "Gijs" } }])).to eq([])
    end

    context "with two collections over one model" do
      before do
        define_collection("Products") { model ShopDb::Product; collection_name "product"; fields :sku, :category }
        define_collection("PublicCategories") { model ShopDb::Category; collection_name "public_category"; fields :id, :parent }
        define_collection("PrivateCategories") do
          model ShopDb::Category
          collection_name "private_category"
          fields :id, :name, :parent

          def scope(_context) = ShopDb::Category.where(id: 2)
        end
      end

      let(:hidden_name) { [{ "$match" => { "sku" => "CAF-1" } }, { "$project" => { "sku" => 1, "name" => "$private.name" } }] }

      it "keeps the private collection's scope on its own join" do
        # CAF-1 is in category 1, which the private collection does not publish.
        expect(rows([lookup("category", from: "private_category", as: "private")] + hidden_name, Products))
          .to eq([{ "sku" => "CAF-1", "name" => nil }])
      end

      it "refuses to rebind a reference an earlier $lookup already joined" do
        # A chained lookup joins `category` with the public collection's rows; rebinding
        # it to the private collection would read those rows under the private fields.
        pipeline = [lookup("category", from: "public_category", as: "public"),
                    lookup("public.parent", from: "public_category", as: "parent"),
                    lookup("category", from: "private_category", as: "private")] + hidden_name
        expect { rows(pipeline, Products) }
          .to raise_error(RorMcp::Pipeline::QueryError, /'category' already joins the 'public_category' collection/)
        expect { rows([lookup("category__parent", from: "public_category", as: "parent"),
                       lookup("category", from: "private_category", as: "private")] + hidden_name, Products) }
          .to raise_error(RorMcp::Pipeline::QueryError, /'category' already joins the 'public_category' collection/)
      end

      it "refuses two collections for one reference, and allows one collection under two aliases" do
        expect { rows([lookup("category", from: "public_category", as: "public"),
                       lookup("category", from: "private_category", as: "private")], Products) }
          .to raise_error(RorMcp::Pipeline::QueryError, /already joins the 'public_category'/)
        result = rows([lookup("category", from: "private_category", as: "a"), lookup("category", from: "private_category", as: "b"),
                       { "$match" => { "sku" => "LAP-1" } }, { "$project" => { "x" => "$a.name", "y" => "$b.id" } }], Products)
        expect(result).to eq([{ "x" => ShopDb::Category.find(2).name, "y" => 2 }])
      end
    end

    it "resolves references to a published subclass (STI / proxy)" do
      vip = Class.new(ShopDb::Customer) { def self.name = "ShopDb::VipCustomer" }
      RorMcp.registry.clear
      define_collection("Orders") { model ShopDb::Order; collection_name "order"; fields :id, :customer }
      define_collection("Vips") { model vip; collection_name "vip"; fields :id, :name }
      catalog = RorMcp::Pipeline::Catalog.new(Orders, RorMcp.registry.collections_for(:default), semantics: :fixed)
      schema = RorMcp::Schema.json_schema(Orders, [], catalog: catalog)
      expect(schema.dig("$jsonSchema", "properties", "customer"))
        .to eq("bsonType" => "objectId", "description" => "Reference to the 'vip' collection", "ref" => "vip")
    end

    it "lets $sort use aliases and _id" do
      # Order 4's customer is outside the customer scope, so c.name is NULL: ascending,
      # PostgreSQL sorts NULLs last, SQLite and MySQL first (Django gets the same order).
      ordered = rows([lookup, { "$sort" => { "c.name" => 1, "_id" => -1 } }, { "$project" => { "id" => 1 } }]).map { |r| r["id"] }
      expect(ordered).to eq(ShopDb.adapter.include?("postg") ? [3, 2, 1, 4] : [4, 3, 2, 1])
    end
  end

  describe "$sort, $skip, $limit" do
    it "takes only 1 and -1" do
      expect { rows([{ "$sort" => { "total" => 0 } }]) }.to raise_error(/must be 1 \(ascending\) or -1 \(descending\), got 0/)
    end

    it "applies $skip and $limit in pipeline order" do
      sorted = [{ "$sort" => { "id" => 1 } }]
      expect(ids(sorted + [{ "$skip" => 1 }, { "$limit" => 2 }])).to eq([2, 3])
      expect(ids(sorted + [{ "$limit" => 3 }, { "$skip" => 1 }])).to eq([2, 3])
    end

    it "lets later stages work on the window" do
      expect(ids([{ "$sort" => { "id" => 1 } }, { "$limit" => 2 }, { "$match" => { "status" => "paid" } }])).to eq([2])
      expect(ids([{ "$sort" => { "id" => 1 } }, { "$limit" => 2 }, { "$sort" => { "id" => -1 } }])).to eq([2, 1])
      expect(rows([{ "$sort" => { "id" => 1 } }, { "$skip" => 2 }, { "$group" => { "_id" => nil, "n" => { "$sum" => 1 } } }]))
        .to eq([{ "n" => 2 }])
    end

    it "applies default_limit and clamps to max_limit" do
      RorMcp.configuration.default_limit = 2
      expect(ids([{ "$sort" => { "id" => 1 } }])).to eq([1, 2])
      RorMcp.configuration.default_limit = nil
      orders.max_limit 3
      expect(ids([{ "$sort" => { "id" => 1 } }, { "$limit" => 50 }])).to eq([1, 2, 3])
    end
  end

  describe "$project" do
    it "supports exclusion" do
      expect(rows([{ "$match" => { "_id" => 1 } }, { "$project" => { "total" => 0, "customer" => 0 } }]))
        .to eq([{ "id" => 1, "number" => "ORD-1", "status" => "cancelled" }])
    end

    it "refuses to mix inclusion and exclusion" do
      expect { rows([{ "$project" => { "number" => 1, "total" => 0 } }]) }.to raise_error(/cannot mix inclusion and exclusion/)
    end
  end

  it "renders an empty result as []" do
    executor = RorMcp::Executor.new(collections, semantics: :fixed)
    expect(executor.call("order", [{ "$match" => { "status" => "nope" } }]).to_h[:content]).to eq([{ type: "text", text: "[]" }])
  end

  describe "safety envelope" do
    it "runs queries with the database in read-only mode, then rolls back" do
      connection = ShopDb::Order.connection
      probe =
        case ShopDb.adapter
        when /sqlite/ then -> { connection.select_value("PRAGMA query_only").to_i == 1 }
        when /postg/ then -> { connection.select_value("SHOW transaction_read_only") == "on" }
        else -> { connection.preventing_writes? } # MySQL: Rails' guard (no read-only switch inside a transaction)
        end
      expect(RorMcp::Envelope.read_only(ShopDb::Order) { probe.call }).to be(true)
      expect(probe.call).to be(false)
    end

    it "applies the statement timeout" do
      skip "SQLite has no statement timeout" if ShopDb.adapter.include?("sqlite")

      query = ShopDb.adapter.include?("postg") ? "SHOW statement_timeout" : "SELECT @@SESSION.max_execution_time"
      seen = RorMcp::Envelope.read_only(ShopDb::Order, timeout: 2.5) { ShopDb::Order.connection.select_value(query) }
      expect(seen.to_s).to eq(ShopDb.adapter.include?("postg") ? "2500ms" : "2500")
    end

    it "refuses writes from tools unless declared writes: true" do
      klass = Class.new(RorMcp::Toolset) do
        tool :rename, description: "Writes without saying so."
        def rename = ShopDb::Customer.find(1).update!(name: "Hacked")
        tool :rename_ok, description: "Declared writer.", writes: true
        def rename_ok = ShopDb::Customer.transaction { ShopDb::Customer.find(1).update!(name: "Anna 2"); raise ActiveRecord::Rollback }
      end
      stub_const("WriterTools", klass)
      result = WriterTools.call(WriterTools.tools["rename"], {}, nil).to_h
      expect(result[:isError]).to be(true)
      expect(result[:content].first[:text]).to match(/Write query attempted while in readonly mode|readonly/i)
      expect(ShopDb::Customer.find(1).name).to eq("Anna")
      expect(WriterTools.call(WriterTools.tools["rename_ok"], {}, nil).to_h[:isError]).to be(false)
    end
  end

  describe "routing_field and multiple databases" do
    before { ShardDb.setup! }

    let!(:events) do
      define_collection("EventCollection") do
        model ShardDb::Event
        collection_name "event"
        fields :id, :name, :customer
        routing_field :region, to: ->(value) { %w[eu us].include?(value) ? { shard: value.to_sym } : nil }
      end
    end

    def query(pipeline)
      RorMcp::Executor.new(collections, semantics: :fixed).call("event", pipeline).to_h
    end

    it "runs the query on the shard the routing field names" do
      expect(query([{ "$match" => { "region" => "eu" } }, { "$project" => { "name" => 1 } }])[:content].first[:text])
        .to eq('[{"name":"signup"},{"name":"order"}]')
      expect(query([{ "$match" => { "region" => { "$eq" => "us" } } }, { "$project" => { "name" => 1 } }])[:content].first[:text])
        .to eq('[{"name":"signup"}]')
    end

    it "requires the routing field and refuses it anywhere but a $match equality" do
      expect(query([])[:content].first[:text]).to match(/'region' is a routing field and is required/)
      expect(query([{ "$match" => { "region" => "mars" } }])[:content].first[:text]).to match(/No database for region "mars"/)
      expect(query([{ "$match" => { "region" => { "$in" => ["eu"] } } }])[:content].first[:text]).to match(/compare it with one value/)
      expect(query([{ "$match" => { "region" => "eu" } }, { "$sort" => { "region" => 1 } }])[:content].first[:text])
        .to match(/'region' is a routing field: it selects the database/)
    end

    it "publishes the routing field and leaves out references into another database" do
      catalog = RorMcp::Pipeline::Catalog.new(events, collections, semantics: :fixed)
      properties = RorMcp::Schema.json_schema(events, [], catalog: catalog).dig("$jsonSchema", "properties")
      expect(properties.keys).to eq(%w[id name region])
      expect(properties["region"]["description"]).to start_with("Routing field")
    end

    it "refuses a $lookup into another database" do
      events.fields :id, :name, :customer
      response = query([{ "$match" => { "region" => "eu" } }, lookup])
      expect(response[:content].first[:text]).to match(/Cannot resolve keyword 'customer'|different databases/)
    end
  end

  describe "description budget" do
    it "warns or raises when the query tool description is too long" do
      RorMcp.configuration.description_budget = 100
      logger = instance_double(Logger, warn: nil)
      RorMcp.logger = logger
      RorMcp.server(:default).tools
      expect(logger).to have_received(:warn).with(/over the description_budget of 100/)

      RorMcp.configuration.description_budget_mode = :raise
      RorMcp.configure { |c| c.description_budget = 100 }
      expect { RorMcp.server(:default).tools }.to raise_error(RorMcp::ConfigurationError, /description_budget/)
    ensure
      RorMcp.logger = nil
    end
  end

  describe "instrumentation" do
    it "reports queries to ActiveSupport::Notifications and on_query" do
      events = []
      RorMcp.configuration.on_query { |event| events << event }
      notified = []
      subscriber = ActiveSupport::Notifications.subscribe("query.ror_mcp") { |*, payload| notified << payload }
      RorMcp::Executor.new(collections, server: :default, semantics: :fixed).call("order", [{ "$match" => { "nope" => 1 } }])
      expect(events.first.to_h).to include(name: "query.ror_mcp", server: :default, collection: "order")
      expect(events.first.error).to match(/Cannot resolve keyword 'nope'/)
      expect(notified.first[:collection]).to eq("order")
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end
end
