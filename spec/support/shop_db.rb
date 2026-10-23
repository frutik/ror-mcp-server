# frozen_string_literal: true

require "active_record"

# An in-memory copy of the parity shop schema (spec/dummy/db/migrate) with a
# few rows, for specs that need real queries without the dummy app.
module ShopDb
  module_function

  def setup!
    return if @ready

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :categories do |t|
        t.string :name, null: false
        t.references :parent
      end
      create_table :customers do |t|
        t.string :name, null: false
        t.string :country, null: false
        t.boolean :active, null: false, default: true
        t.date :signed_up_on, null: false
        t.text :notes
      end
      create_table :products, id: false do |t|
        t.string :sku, primary_key: true
        t.string :name, null: false
        t.text :description, null: false, default: ""
        t.decimal :price, precision: 10, scale: 2, null: false
        t.references :category, null: false
        t.json :specs
      end
      create_table :orders do |t|
        t.string :number, null: false
        t.references :customer, null: false
        t.references :billing_identity
        t.string :status, null: false
        t.decimal :total, precision: 10, scale: 2, null: false
        t.datetime :placed_at, null: false
        t.json :metadata
      end
    end
    seed!
    @ready = true
  end

  # insert_all! needs every row to carry the same keys.
  def insert(model, rows)
    keys = rows.flat_map(&:keys).uniq
    model.insert_all!(rows.map { |row| keys.to_h { |k| [k, row[k]] } })
  end

  def seed!
    insert(ShopDb::Category, [{ id: 1, name: "Electronics" }, { id: 2, name: "Laptops", parent_id: 1 }])
    insert(ShopDb::Customer, [
      { id: 1, name: "Anna", country: "NL", active: true, signed_up_on: "2023-02-21" },
      { id: 2, name: "Bram", country: "BE", active: true, signed_up_on: "2023-03-30", notes: "vip" },
      { id: 3, name: "Gijs", country: "NL", active: false, signed_up_on: "2023-09-01" },
    ])
    insert(ShopDb::Product, [
      { sku: "LAP-1", name: "Laptop", description: "14 inch", price: "899.00", category_id: 2, specs: { "ram_gb" => 16 } },
      { sku: "CAF-1", name: "Café machine", description: "", price: "429.50", category_id: 1 },
    ])
    insert(ShopDb::Order, [
      { id: 1, number: "ORD-1", customer_id: 2, status: "cancelled", total: "499.90", placed_at: "2024-11-26T12:23:00Z",
        metadata: { "channel" => "web" } },
      { id: 2, number: "ORD-2", customer_id: 2, billing_identity_id: 1, status: "paid", total: "2386.90",
        placed_at: "2024-12-19T17:53:00.250000Z" },
      { id: 3, number: "ORD-3", customer_id: 1, status: "paid", total: "6549.00", placed_at: "2025-01-11T22:10:00Z" },
      { id: 4, number: "ORD-4", customer_id: 3, billing_identity_id: 2, status: "pending", total: "120.00",
        placed_at: "2025-02-03T10:20:00Z" },
    ])
  end

  class Record < ActiveRecord::Base
    self.abstract_class = true
  end

  # A node of the product category tree.
  class Category < Record
    self.table_name = "categories"
    belongs_to :parent, class_name: "ShopDb::Category", optional: true
  end

  class Customer < Record
    self.table_name = "customers"
    enum :country, { "NL" => "NL", "BE" => "BE" }
  end

  class Product < Record
    self.table_name = "products"
    self.primary_key = "sku"
    belongs_to :category, class_name: "ShopDb::Category"
  end

  class Order < Record
    self.table_name = "orders"
    enum :status, { pending: "pending", paid: "paid", cancelled: "cancelled" }
    belongs_to :customer, class_name: "ShopDb::Customer"
    belongs_to :billing_identity, class_name: "ShopDb::Customer", optional: true
  end
end
