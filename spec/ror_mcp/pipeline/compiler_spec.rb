# frozen_string_literal: true

# django-mcp-server semantics (`:parity`, PLAN §1A.6–7) on a real database.
# `:fixed` semantics: fixed_semantics_spec.rb.
RSpec.describe RorMcp::Pipeline::Compiler do
  before { ShopDb.setup! }

  let(:orders) do
    define_collection("OrderCollection") do
      model ShopDb::Order
      fields :all
    end
  end

  let(:orders_with_customers) do
    customers
    orders
  end

  let(:customers) do
    define_collection("CustomerCollection") do
      model ShopDb::Customer
      fields :id, :name
    end
  end

  # Every collection defined in the example is "published on the server".
  def rows(pipeline, collection = orders, relation: collection.model.all)
    collections = RorMcp.registry.published.to_h { |c| [c.name, c] }
    described_class.new(collection, relation, collections: collections, semantics: :parity).rows(JSON.parse(JSON.generate(pipeline)))
  end

  def ids(pipeline, collection = orders, **options)
    rows(pipeline + [{ "$project" => { "id" => 1 } }], collection, **options).map { |r| r["id"] }
  end

  describe "$match" do
    it "compares literals, operators, dates and decimals" do
      expect(ids([{ "$match" => { "status" => "paid" } }])).to eq([2, 3])
      expect(ids([{ "$match" => { "total" => { "$gt" => 500, "$lt" => 3000 } } }])).to eq([2])
      expect(ids([{ "$match" => { "placed_at" => { "$gte" => "2025-01-01T00:00:00Z" } } }])).to eq([3, 4])
      expect(ids([{ "$match" => { "status" => { "$in" => %w[pending cancelled] } } }])).to eq([1, 4])
    end

    it "matches the primary key as _id and a belongs_to by name or column" do
      expect(ids([{ "$match" => { "_id" => 3 } }])).to eq([3])
      expect(ids([{ "$match" => { "customer" => 2 } }])).to eq([1, 2])
      expect(ids([{ "$match" => { "customer_id" => 2 } }])).to eq([1, 2])
    end

    it "treats null as IS NULL" do
      expect(ids([{ "$match" => { "billing_identity" => nil } }])).to eq([1, 3])
      expect(ids([{ "$match" => { "billing_identity" => { "$eq" => nil } } }])).to eq([1, 3])
      expect(ids([{ "$match" => { "billing_identity" => { "$ne" => nil } } }])).to eq([2, 4])
    end

    it "keeps NULL rows under $ne/$nin on a nullable column, as Django's negated Q does" do
      expect(ids([{ "$match" => { "billing_identity" => { "$ne" => 1 } } }])).to eq([1, 3, 4])
      expect(ids([{ "$match" => { "billing_identity" => { "$nin" => [1, 2] } } }])).to eq([1, 3])
      expect(ids([{ "$match" => { "$nor" => [{ "billing_identity" => 1 }] } }])).to eq([1, 3, 4])
    end

    it "supports $and, $or and $nor, ignoring keys next to them" do
      expect(ids([{ "$match" => { "$and" => [{ "status" => "paid" }, { "customer" => 1 }] } }])).to eq([3])
      expect(ids([{ "$match" => { "$or" => [{ "status" => "pending" }, { "total" => { "$lt" => 500 } }] } }])).to eq([1, 4])
      expect(ids([{ "$match" => { "$or" => [{ "status" => "paid" }], "customer" => 1 } }])).to eq([2, 3])
    end

    it "matches $regex case-sensitively (SQLite gets a REGEXP function)" do
      RorMcp::Adapters.prepare(ShopDb::Order.connection)
      expect(ids([{ "$match" => { "number" => { "$regex" => "^ORD-[12]$" } } }])).to eq([1, 2])
      expect(ids([{ "$match" => { "number" => { "$regex" => "^ord" } } }])).to eq([])
    end

    it "reaches columns outside `fields`" do
      RorMcp.registry.clear
      expect(ids([{ "$match" => { "notes" => "vip" } }], customers)).to eq([2])
    end

    it "rejects unknown fields and operators" do
      expect { rows([{ "$match" => { "nope" => 1 } }]) }.to raise_error(RorMcp::Pipeline::QueryError, /Cannot resolve keyword 'nope'.*customer_id/)
      expect { rows([{ "$match" => { "status" => { "$foo" => 1 } } }]) }.to raise_error(RorMcp::Pipeline::QueryError, /Unsupported operator \$foo/)
      expect { rows([{ "$match" => { "status" => { "eq" => 1 } } }]) }.to raise_error(RorMcp::Pipeline::QueryError, /Unknown match key: eq/)
    end
  end

  describe "$sort, $limit, $skip" do
    it "sorts ascending only for 1; any other direction is descending" do
      expect(ids([{ "$sort" => { "total" => 1 } }])).to eq([4, 1, 2, 3])
      expect(ids([{ "$sort" => { "total" => -1 } }])).to eq([3, 2, 1, 4])
      expect(ids([{ "$sort" => { "total" => 0 } }])).to eq([3, 2, 1, 4])
    end

    it "applies $skip after $limit, whatever their order" do
      expect(ids([{ "$sort" => { "id" => 1 } }, { "$skip" => 1 }, { "$limit" => 3 }])).to eq([2, 3])
      expect(ids([{ "$sort" => { "id" => 1 } }, { "$limit" => 3 }, { "$skip" => 1 }])).to eq([2, 3])
      expect(ids([{ "$sort" => { "id" => 1 } }, { "$skip" => 3 }])).to eq([4])
      expect(ids([{ "$limit" => 2 }, { "$skip" => 5 }])).to eq([])
    end

    it "keeps the smaller of two limits" do
      expect(ids([{ "$sort" => { "id" => 1 } }, { "$limit" => 3 }, { "$limit" => 2 }])).to eq([1, 2])
    end

    it "refuses to filter or sort after a slice, like a sliced QuerySet" do
      expect { rows([{ "$limit" => 2 }, { "$match" => { "status" => "paid" } }]) }.to raise_error(/once a slice has been taken/)
      expect { rows([{ "$limit" => 2 }, { "$sort" => { "id" => 1 } }]) }.to raise_error(/once a slice has been taken/)
    end

    it "does not translate _id in $sort" do
      expect { rows([{ "$sort" => { "_id" => 1 } }]) }.to raise_error(/Cannot resolve keyword '_id'/)
    end
  end

  describe "$project and output rows" do
    it "returns every column, foreign keys as <name>_id, without $project" do
      expect(rows([{ "$match" => { "_id" => 1 } }]).first.keys)
        .to eq(%w[id number customer_id billing_identity_id status total placed_at metadata])
    end

    it "includes truthy fields, maps $paths, ignores 0 and nests dotted keys" do
      result = rows([{ "$match" => { "_id" => 1 } },
                     { "$project" => { "_id" => 1, "number" => 1, "status" => 0, "who" => "$customer", "x.total" => "$total" } }])
      expect(result).to eq([{ "_id" => 1, "number" => "ORD-1", "who" => 2, "x" => { "total" => BigDecimal("499.9") } }])
    end

    it "returns every column when the projection only excludes" do
      expect(rows([{ "$match" => { "_id" => 1 } }, { "$project" => { "status" => 0 } }]).first.keys.size).to eq(8)
    end

    it "rejects $project before $group" do
      expect { rows([{ "$project" => { "status" => 1 } }, { "$group" => { "_id" => nil } }]) }.to raise_error(/\$project cannot appear/)
    end

    it "starts from the relation it is given (the collection's scope)" do
      expect(ids([], orders, relation: ShopDb::Order.where(status: "paid"))).to eq([2, 3])
    end
  end

  it "rejects unknown stages with Python's repr of the stage" do
    expect { rows([{ "$unwind" => "$items" }]) }.to raise_error("Unsupported stage {'$unwind': '$items'} : please review pipeline syntax constraints")
  end

  describe "$group" do
    it "aggregates everything with _id null into one row with plain keys" do
      expect(rows([{ "$group" => { "_id" => nil, "n" => { "$sum" => 1 }, "revenue" => { "$sum" => "$total" },
                                   "a.b" => { "$count" => "$billing_identity" } } }]))
        .to eq([{ "n" => 4, "revenue" => BigDecimal("9555.8"), "a.b" => 2 }])
    end

    it "puts a single key under the field's own name, after the accumulators" do
      result = rows([{ "$match" => { "status" => { "$ne" => "cancelled" } } },
                     { "$group" => { "_id" => "$status", "n" => { "$count" => 1 }, "top" => { "$max" => "$total" } } }])
      # Without $sort the group order is the database's (PostgreSQL hash-aggregates).
      expect(result).to contain_exactly({ "n" => 2, "top" => BigDecimal("6549"), "status" => "paid" },
                                        { "n" => 1, "top" => BigDecimal("120"), "status" => "pending" })
    end

    it "nests object keys under _id and follows lookup aliases" do
      result = rows([{ "$lookup" => { "from" => "customer", "localField" => "customer", "foreignField" => "_id", "as" => "c" } },
                     { "$group" => { "_id" => { "country" => "$c.country" }, "n" => { "$sum" => 1 } } }], orders_with_customers)
      expect(result).to contain_exactly({ "n" => 2, "_id" => { "country" => "BE" } }, { "n" => 2, "_id" => { "country" => "NL" } })
    end

    it "averages decimals to 15 significant digits, like Django on SQLite" do
      expect(rows([{ "$group" => { "_id" => nil, "avg" => { "$avg" => "$total" } } }])).to eq([{ "avg" => 2388.95 }])
    end

    it "aggregates within a $limit (subquery) and ignores $skip" do
      expect(rows([{ "$sort" => { "id" => 1 } }, { "$skip" => 1 }, { "$limit" => 2 }, { "$group" => { "_id" => nil, "n" => { "$sum" => 1 } } }]))
        .to eq([{ "n" => 2 }])
    end

    it "counts with COUNT(*), so models without an id column work (documented deviation)" do
      define_collection("ProductCollection") { model ShopDb::Product; fields :all }
      expect(rows([{ "$group" => { "_id" => nil, "n" => { "$sum" => 1 } } }], ProductCollection)).to eq([{ "n" => 2 }])
    end

    it "returns {} without accumulators" do
      expect(rows([{ "$group" => { "_id" => nil } }])).to eq([{}])
    end

    it "validates like django-mcp-server" do
      expect { rows([{ "$group" => { "_id" => nil } }, { "$limit" => 1 }]) }.to raise_error(/must be the last stage/)
      expect { rows([{ "$group" => { "_id" => nil, "x" => { "$push" => "$id" } } }]) }.to raise_error(/Unsupported aggregation operator: \$push/)
      expect { rows([{ "$group" => { "_id" => nil, "x" => { "$sum" => 2 } } }]) }.to raise_error(/\$sum only supports 1/)
      expect { rows([{ "$group" => { "_id" => nil, "x" => { "$avg" => 1 } } }]) }.to raise_error(/\$avg requires a field reference/)
      expect { rows([{ "$group" => { "_id" => 5 } }]) }.to raise_error(/Unsupported _id value/)
      expect { rows([{ "$group" => { "_id" => "status" } }]) }.to raise_error(/Unsupported _id value/)
    end
  end

  describe "$text and $search" do
    let(:products) do
      define_collection("ProductCollection") do
        model ShopDb::Product
        fields :all
        search_fields :name, :description
      end
    end

    it "needs every word to match some search field, case-insensitively" do
      expect(rows([{ "$match" => { "$text" => { "$search" => "LAPTOP 14" } } }, { "$project" => { "sku" => 1 } }], products))
        .to eq([{ "sku" => "LAP-1" }])
      expect(rows([{ "$match" => { "$text" => { "$search" => "laptop café" } } }], products)).to eq([])
    end

    it "combines $text with the rest of the $match" do
      expect(rows([{ "$match" => { "$text" => { "$search" => "a" }, "price" => { "$lt" => 500 } } }, { "$project" => { "sku" => 1 } }], products))
        .to eq([{ "sku" => "CAF-1" }])
    end

    it "treats % and _ literally" do
      expect(rows([{ "$match" => { "$text" => { "$search" => "%" } } }], products)).to eq([])
    end

    it "restricts $search to a path within the search fields" do
      expect(rows([{ "$search" => { "text" => { "query" => "inch", "path" => "description" } } }, { "$project" => { "sku" => 1 } }], products))
        .to eq([{ "sku" => "LAP-1" }])
      expect { rows([{ "$search" => { "text" => { "query" => "x", "path" => "sku" } } }], products) }.to raise_error(/not allowed for search/)
    end

    it "is unavailable without search fields" do
      define_collection("Plain") { model ShopDb::Order; fields :id }
      expect { rows([{ "$match" => { "$text" => { "$search" => "x" } } }], Plain) }.to raise_error(/full text search is not supported/)
    end
  end

  describe "extended operators (extra_filters)" do
    let(:filtered) do
      define_collection("Filtered") do
        model ShopDb::Order
        fields :all
        extra_filters :icontains, :startswith, :endswith, :year, :month, :range, :date
      end
    end

    it "applies the enabled Django lookups" do
      expect(ids([{ "$match" => { "number" => { "$icontains" => "rd-3" } } }], filtered)).to eq([3])
      expect(ids([{ "$match" => { "number" => { "$startswith" => "ORD-" }, "status" => { "$endswith" => "id" } } }], filtered)).to eq([2, 3])
      expect(ids([{ "$match" => { "placed_at" => { "$year" => 2025 } } }], filtered)).to eq([3, 4])
      expect(ids([{ "$match" => { "placed_at" => { "$month" => 12 } } }], filtered)).to eq([2])
      expect(ids([{ "$match" => { "total" => { "$range" => [100, 500] } } }], filtered)).to eq([1, 4])
      expect(ids([{ "$match" => { "placed_at" => { "$date" => "2025-01-11" } } }], filtered)).to eq([3])
    end

    it "rejects lookups that are not enabled" do
      expect { rows([{ "$match" => { "number" => { "$icontains" => "x" } } }]) }.to raise_error(/Unsupported operator \$icontains/)
    end
  end

  describe "computed fields" do
    let(:with_computed) do
      define_collection("Computed") do
        model ShopDb::Customer
        collection_name "customer"
        fields :id, :name
        computed :order_count, :integer, sql: "SELECT count(*) FROM orders WHERE orders.customer_id = {table}.id",
                                         doc: "orders placed"
      end
    end

    it "can be filtered, sorted, projected and grouped" do
      result = rows([{ "$match" => { "order_count" => { "$gte" => 1 } } }, { "$sort" => { "order_count" => -1 } },
                     { "$project" => { "name" => 1, "order_count" => 1 } }], with_computed)
      expect(result).to eq([{ "name" => "Bram", "order_count" => 2 }, { "name" => "Anna", "order_count" => 1 }, { "name" => "Gijs", "order_count" => 1 }])
      expect(rows([{ "$group" => { "_id" => nil, "total" => { "$sum" => "$order_count" } } }], with_computed)).to eq([{ "total" => 4 }])
    end

    it "is reachable through $lookup, with {table} bound to the join alias" do
      with_computed
      collections = { "order" => orders, "customer" => with_computed }
      result = described_class.new(orders, ShopDb::Order.all, collections: collections, semantics: :parity).rows(
        [{ "$lookup" => { "from" => "customer", "localField" => "customer", "foreignField" => "_id", "as" => "c" } },
         { "$match" => { "_id" => 4 } }, { "$project" => { "who" => "$c.name", "their_orders" => "$c.order_count" } }],
      )
      expect(result).to eq([{ "who" => "Gijs", "their_orders" => 1 }])
    end

    it "is published in the schema" do
      expect(RorMcp::Schema.json_schema(with_computed, [ShopDb::Customer]).dig("$jsonSchema", "properties", "order_count"))
        .to eq("bsonType" => "int", "description" => "orders placed. Computed value, not a stored column or reference.")
    end
  end

  describe "$lookup" do
    let(:published) { [ShopDb::Order, ShopDb::Customer, ShopDb::Category, ShopDb::Product] }

    def lookup_rows(pipeline, collection = orders)
      collections = published.each_with_index.to_h { |model, i| ["c#{i}", Class.new(RorMcp::Collection).tap { |c| c.model(model) }] }
      described_class.new(collection, collection.model.all, collections: collections, semantics: :parity)
                     .rows(JSON.parse(JSON.generate(pipeline)))
    end

    def customer_lookup(local = "customer", as: "c", from: "customer")
      { "$lookup" => { "from" => from, "localField" => local, "foreignField" => "_id", "as" => as } }
    end

    it "joins through alias.field in $project and $match" do
      result = lookup_rows([customer_lookup, { "$match" => { "c.country" => "BE" } }, { "$sort" => { "id" => 1 } },
                            { "$project" => { "number" => 1, "who" => "$c.name" } }])
      expect(result).to eq([{ "number" => "ORD-1", "who" => "Bram" }, { "number" => "ORD-2", "who" => "Bram" }])
    end

    it "reads every $lookup first, wherever it sits" do
      result = lookup_rows([{ "$match" => { "c.name" => "Anna" } }, customer_lookup, { "$project" => { "id" => 1 } }])
      expect(result).to eq([{ "id" => 3 }])
    end

    it "casts joined values with their own model's types" do
      result = lookup_rows([customer_lookup("customer_id"), { "$sort" => { "id" => 1 } },
                            { "$project" => { "id" => 1, "since" => "$c.signed_up_on", "active" => "$c.active" } }])
      expect(result.first).to eq("id" => 1, "since" => Date.new(2023, 3, 30), "active" => true)
    end

    it "chains lookups through an alias and joins a model to itself" do
      define_collection("CategoryCollection") { model ShopDb::Category; fields :all }
      result = lookup_rows([{ "$lookup" => { "from" => "category", "localField" => "parent", "foreignField" => "_id", "as" => "p" } },
                            { "$sort" => { "id" => 1 } }, { "$project" => { "name" => 1, "parent" => "$p.name" } }], CategoryCollection)
      expect(result).to eq([{ "name" => "Electronics", "parent" => nil }, { "name" => "Laptops", "parent" => "Electronics" }])
    end

    it "does not apply the target collection's scope (django-mcp-server quirk)" do
      result = lookup_rows([customer_lookup, { "$match" => { "c.active" => false } }, { "$project" => { "id" => 1 } }])
      expect(result).to eq([{ "id" => 4 }])
    end

    it "accepts any published model as `from`, not only the reference's target (quirk)" do
      result = lookup_rows([customer_lookup(from: "product"), { "$match" => { "_id" => 3 } }, { "$project" => { "who" => "$c.name" } }])
      expect(result).to eq([{ "who" => "Anna" }])
    end

    it "mangles localField names containing _id (quirk)" do
      expect { lookup_rows([customer_lookup("billing_identity", as: "b"), { "$match" => { "b.name" => "Anna" } }]) }
        .to raise_error(RorMcp::Pipeline::QueryError, /Cannot resolve keyword 'billingentity'/)
    end

    it "rejects unpublished targets, non-references, bad foreignFields and unknown aliases" do
      expect { lookup_rows([customer_lookup(from: "user")]) }.to raise_error(/Invalid lookup from collection 'user'/)
      expect { lookup_rows([customer_lookup("status")]) }.to raise_error(/is not a reference/)
      expect { lookup_rows([{ "$lookup" => { "from" => "customer", "localField" => "customer", "foreignField" => "name", "as" => "c" } }]) }
        .to raise_error(/Invalid foreignField 'name'/)
      expect { lookup_rows([{ "$match" => { "x.name" => 1 } }]) }.to raise_error(/Unknown lookup alias 'x'/)
    end

    it "does not translate aliases in $sort, like Django's order_by" do
      expect { lookup_rows([customer_lookup, { "$sort" => { "c.name" => 1 } }]) }.to raise_error(/Cannot resolve keyword 'c.name'/)
    end
  end
end
