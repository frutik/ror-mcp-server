# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_23_000000) do
  create_table "categories", force: :cascade do |t|
    t.string "name", limit: 100, null: false
    t.string "slug", limit: 100, null: false
    t.integer "parent_id"
    t.index ["parent_id"], name: "index_categories_on_parent_id"
    t.index ["slug"], name: "index_categories_on_slug", unique: true
  end

  create_table "customers", force: :cascade do |t|
    t.string "name", limit: 100, null: false
    t.string "email", limit: 200, null: false
    t.string "country", limit: 2, null: false
    t.boolean "active", default: true, null: false
    t.date "signed_up_on", null: false
    t.text "notes"
  end

  create_table "line_items", force: :cascade do |t|
    t.integer "order_id", null: false
    t.string "product_id", limit: 20, null: false
    t.integer "quantity", null: false
    t.decimal "unit_price", precision: 10, scale: 2, null: false
    t.index ["order_id"], name: "index_line_items_on_order_id"
    t.index ["product_id"], name: "index_line_items_on_product_id"
  end

  create_table "orders", force: :cascade do |t|
    t.string "number", limit: 20, null: false
    t.integer "customer_id", null: false
    t.integer "billing_identity_id"
    t.string "status", limit: 20, null: false
    t.decimal "total", precision: 10, scale: 2, null: false
    t.datetime "placed_at", null: false
    t.json "metadata"
    t.index ["billing_identity_id"], name: "index_orders_on_billing_identity_id"
    t.index ["customer_id"], name: "index_orders_on_customer_id"
    t.index ["number"], name: "index_orders_on_number", unique: true
  end

  create_table "products", primary_key: "sku", id: { type: :string, limit: 20 }, force: :cascade do |t|
    t.string "name", limit: 200, null: false
    t.text "description", default: "", null: false
    t.decimal "price", precision: 10, scale: 2, null: false
    t.integer "category_id", null: false
    t.boolean "in_stock", default: true, null: false
    t.json "specs"
    t.index ["category_id"], name: "index_products_on_category_id"
  end

  add_foreign_key "categories", "categories", column: "parent_id"
  add_foreign_key "line_items", "orders"
  add_foreign_key "line_items", "products", primary_key: "sku"
  add_foreign_key "orders", "customers"
  add_foreign_key "orders", "customers", column: "billing_identity_id"
  add_foreign_key "products", "categories"
end
