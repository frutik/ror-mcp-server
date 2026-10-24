# frozen_string_literal: true

# What `:fixed` promises, checked across scope shapes × the ways a pipeline can
# reach a collection's rows (PLAN §1B):
#
#   rows    — whatever the pipeline, a client sees only rows the collection's
#             scope publishes (ActiveRecord's own answer for that scope);
#   fields  — only the collection's `fields` can be read, filtered, sorted or grouped;
#   ceiling — no query returns more than `max_limit` rows; a $group that would
#             (its output can't be paged) is refused.
#
# A combination that fails because of a known open issue is marked pending with
# its SECURITY_AUDIT id; RSpec fails it once it starts passing, so fixing the
# issue means deleting its entry from `known`.
RSpec.describe "fixed semantics contract" do
  before do
    ShopDb.setup!
    RorMcp.configuration.pipeline_semantics = :fixed
  end

  after { RorMcp.reset! }

  def self.pending_if(reason) = reason ? { pending: reason } : {}

  customer = ShopDb::Customer
  scopes = {
    "no scope" => -> { customer.all },
    "a where" => -> { customer.where(active: true) },
    "an or" => -> { customer.where(id: 1).or(customer.where(id: 3)) },
    "a subquery condition" => -> { customer.where(id: ShopDb::Order.where(status: "paid").select(:customer_id)) },
    "a FROM subquery" => -> { customer.from(customer.where(active: true), :customers) },
    "a HAVING" => -> { customer.group(:id).having(Arel.sql("MAX(CASE WHEN active THEN 1 ELSE 0 END) = 1")) },
    "an ordering" => -> { customer.order(:name) },
    "an offset" => -> { customer.order(:id).offset(1) },
    "a limit" => -> { customer.order(:id).limit(2) },
    "limit(0)" => -> { customer.limit(0) },
  }

  ids = [1, 2, 3]
  names = %w[Anna Bram Gijs]
  pair = { "$project" => { "i" => "$id", "n" => "$name" } }
  lookup = ->(local, as) { { "$lookup" => { "from" => "customer", "localField" => local, "foreignField" => "_id", "as" => as } } }
  c = lookup.call("customer", "c")
  c_pair = { "$project" => { "i" => "$c.id", "n" => "$c.name" } }

  # label → [queried collection, pipelines]; each pipeline yields [id, name] pairs of customers.
  paths = {
    "a direct query" => [:customers, [[pair]]],
    "$match on the key" => [:customers, ids.map { |id| [{ "$match" => { "_id" => id } }, pair] }],
    "$match on a field" => [:customers, names.map { |name| [{ "$match" => { "name" => name } }, pair] }],
    "$sort" => [:customers, [[{ "$sort" => { "name" => -1 } }, pair]]],
    "$skip" => [:customers, [[{ "$skip" => 1 }, pair]]],
    "$sort, $limit" => [:customers, [[{ "$sort" => { "_id" => -1 } }, { "$limit" => 1 }, pair]]],
    "$group" => [:customers, [[{ "$group" => { "_id" => { "i" => "$id", "n" => "$name" } } }]]],
    "$group with a count" => [:customers, [[{ "$group" => { "_id" => { "i" => "$id", "n" => "$name" }, "k" => { "$sum" => 1 } } }]]],
    "$lookup" => [:orders, [[c, c_pair]]],
    "$lookup, $match on its field" => [:orders, names.map { |name| [c, { "$match" => { "c.name" => name } }, c_pair] }],
    "$lookup, $sort on its field" => [:orders, [[c, { "$sort" => { "c.name" => -1 } }, c_pair]]],
    "$lookup after $sort, $limit" => [:orders, [[{ "$sort" => { "_id" => -1 } }, { "$limit" => 10 }, c, c_pair]]],
    "$lookup, $group on its fields" => [:orders, [[c, { "$group" => { "_id" => { "i" => "$c.id", "n" => "$c.name" }, "k" => { "$sum" => 1 } } }]]],
    "$lookup through a second reference" => [:orders, [[lookup.call("billing_identity", "b"),
                                                        { "$project" => { "i" => "$b.id", "n" => "$b.name" } }]]],
  }

  # [scope, path] → why it fails today (none at the moment).
  known = {}

  let!(:customers) do
    define_collection("ContractCustomers") do
      model ShopDb::Customer
      collection_name "customer"
      fields :id, :name
    end
  end

  let!(:orders) do
    define_collection("ContractOrders") do
      model ShopDb::Order
      collection_name "order"
      fields :id, :number, :customer, :billing_identity
    end
  end

  def rows(collection, pipeline)
    collections = RorMcp.registry.collections_for(:default)
    RorMcp::Pipeline::Compiler.new(collection, collection.new.scope(nil), collections: collections, semantics: :fixed)
                              .rows(JSON.parse(JSON.generate(pipeline)))
  end

  def pairs(rows)
    rows.map { |row| row.key?("_id") ? row["_id"] : row }.map { |row| [row["i"], row["n"]] }.reject { |id, _| id.nil? }
  end

  describe "rows" do
    scopes.each do |scope_label, scope|
      paths.each do |path_label, (queried, pipelines)|
        it "#{path_label} sees only what #{scope_label} publishes", **pending_if(known[[scope_label, path_label]]) do
          customers.define_method(:scope) { |_context| scope.call }
          published = scope.call.map { |r| [r.id, r.name] }
          seen = pipelines.flat_map { |pipeline| pairs(rows(public_send(queried), pipeline)) }.uniq

          expect(seen - published).to eq([])
          expect(seen).not_to be_empty if scope_label == "no scope"
        end
      end
    end
  end

  describe "fields" do
    hidden = { "notes" => "$notes", "c.notes" => "$c.notes" }
    attempts = {
      "$match" => [:customers, { "$match" => { "notes" => "vip" } }],
      "$match with an operator" => [:customers, { "$match" => { "notes" => { "$regex" => "v" } } }],
      "$match inside $or" => [:customers, { "$match" => { "$or" => [{ "notes" => "vip" }] } }],
      "$sort" => [:customers, { "$sort" => { "notes" => 1 } }],
      "$project" => [:customers, { "$project" => { "x" => hidden["notes"] } }],
      "$group key" => [:customers, { "$group" => { "_id" => hidden["notes"] } }],
      "$group accumulator" => [:customers, { "$group" => { "_id" => nil, "x" => { "$max" => hidden["notes"] } } }],
      "$lookup, $match" => [:orders, c, { "$match" => { "c.notes" => "vip" } }],
      "$lookup, $sort" => [:orders, c, { "$sort" => { "c.notes" => 1 } }],
      "$lookup, $project" => [:orders, c, { "$project" => { "x" => hidden["c.notes"] } }],
      "$lookup, $group key" => [:orders, c, { "$group" => { "_id" => hidden["c.notes"] } }],
      "$lookup, $group accumulator" => [:orders, c, { "$group" => { "_id" => nil, "x" => { "$max" => hidden["c.notes"] } } }],
    }

    attempts.each do |label, (queried, *pipeline)|
      it "refuses a field outside `fields` in #{label}" do
        expect { rows(public_send(queried), pipeline) }.to raise_error(RorMcp::Pipeline::QueryError, /'(c\.)?notes'|notes/)
      end
    end

    # Primary keys are always addressable as `_id` and `pk`, even when `fields` leaves them out
    # (ADR 0014): a reference such as order.customer shows them anyway, and joins need them.
    # `fields` still decides the column name, rows without $project, and the schema.
    # label → [queried collection, pipeline, keys it yields]
    keys = {
      "$project $_id" => [:customers, [{ "$project" => { "x" => "$_id" } }], ids],
      "$project $pk" => [:customers, [{ "$project" => { "x" => "$pk" } }], ids],
      "$match _id" => [:customers, [{ "$match" => { "_id" => 3 } }, { "$project" => { "x" => "$_id" } }], [3]],
      "$group by _id" => [:customers, [{ "$group" => { "_id" => "$_id", "n" => { "$sum" => 1 } } }], ids],
      "$lookup, $project $c._id" => [:orders, [c, { "$project" => { "x" => "$c._id" } }], ids],
      "$lookup, $project $c.pk" => [:orders, [c, { "$project" => { "x" => "$c.pk" } }], ids],
    }

    keys.each do |label, (queried, pipeline, expected)|
      it "addresses the primary key of a collection that leaves it out of `fields`, in #{label}" do
        customers.fields :name
        values = rows(public_send(queried), pipeline).map { |row| row["x"] || row["_id"] }
        expect(values.uniq.sort).to eq(expected)
      end
    end

    it "keeps the key's column name, rows without $project and the schema to `fields`" do
      customers.fields :name
      expect { rows(customers, [{ "$project" => { "x" => "$id" } }]) }.to raise_error(RorMcp::Pipeline::QueryError, /'id'/)
      to_customer = { "$lookup" => { "from" => "customer", "localField" => "customer", "foreignField" => "_id", "as" => "c" } }
      expect { rows(orders, [to_customer, { "$project" => { "x" => "$c.id" } }]) }.to raise_error(RorMcp::Pipeline::QueryError, /'id'/)
      expect(rows(customers, []).flat_map(&:keys).uniq).to eq(["name"])
      catalog = RorMcp::Pipeline::Catalog.new(customers, RorMcp.registry.collections_for(:default), semantics: :fixed)
      expect(RorMcp::Schema.json_schema(customers, [], catalog: catalog).dig("$jsonSchema", "properties").keys).to eq(["name"])
    end
  end

  describe "ceiling" do
    before do
      RorMcp.configuration.default_limit = 1
      RorMcp.configuration.max_limit = 1
    end

    pipelines = {
      "no $limit" => [:customers, []],
      "a $limit above max_limit" => [:customers, [{ "$limit" => 5 }]],
      "$group by a field" => [:customers, [{ "$group" => { "_id" => "$name", "k" => { "$sum" => 1 } } }]],
      "$group without accumulators" => [:customers, [{ "$group" => { "_id" => { "i" => "$id" } } }]],
      "$lookup, $group" => [:orders, [c, { "$group" => { "_id" => "$c.name", "k" => { "$sum" => 1 } } }]],
    }

    # The rows a query returns, or nil when it is refused for exceeding max_limit.
    def capped(collection, pipeline)
      rows(collection, pipeline)
    rescue RorMcp::Pipeline::QueryError => e
      raise unless e.message.include?("max_limit")
    end

    pipelines.each do |label, (queried, pipeline)|
      it "returns at most max_limit rows for #{label}" do
        result = capped(public_send(queried), pipeline)
        expect(result.size).to be <= 1 if result
      end
    end

    it "returns at most max_limit rows when default_limit is nil" do
      RorMcp.configuration.default_limit = nil
      expect(rows(customers, []).size).to eq(1)
    end

    it "answers a $group that fits within max_limit" do
      expect(rows(customers, [{ "$group" => { "_id" => nil, "k" => { "$sum" => 1 } } }])).to eq([{ "k" => 3 }])
      expect(rows(customers, [{ "$match" => { "name" => "Anna" } }, { "$group" => { "_id" => "$name", "k" => { "$sum" => 1 } } }]))
        .to eq([{ "name" => "Anna", "k" => 1 }])
    end
  end
end
