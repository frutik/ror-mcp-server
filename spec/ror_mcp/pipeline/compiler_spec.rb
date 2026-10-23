# frozen_string_literal: true

# django-mcp-server semantics (`:parity`, PLAN §1A.6–7) on a real database.
RSpec.describe RorMcp::Pipeline::Compiler do
  before { ShopDb.setup! }

  let(:orders) do
    define_collection("OrderCollection") do
      model ShopDb::Order
      fields :all
    end
  end

  let(:customers) do
    define_collection("CustomerCollection") do
      model ShopDb::Customer
      fields :id, :name
    end
  end

  def rows(pipeline, collection = orders, relation: collection.model.all)
    described_class.new(collection, relation).rows(JSON.parse(JSON.generate(pipeline)))
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

  it "names the milestone of stages not built yet" do
    expect { rows([{ "$lookup" => {} }]) }.to raise_error(RorMcp::Pipeline::NotYetSupported, /M3/)
    expect { rows([{ "$group" => { "_id" => nil } }]) }.to raise_error(RorMcp::Pipeline::NotYetSupported, /M4/)
  end
end
