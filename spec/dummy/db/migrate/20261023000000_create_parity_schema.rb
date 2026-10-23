# Mirrors spec/parity/django_app/shop/models.py: same tables, columns and keys,
# so both apps load spec/parity/fixtures/data.json identically.
# Column comments carry Django's help_text (ignored by SQLite, kept for Postgres).
class CreateParitySchema < ActiveRecord::Migration[8.1]
  def change
    create_table :categories do |t|
      t.string :name, limit: 100, null: false
      t.string :slug, limit: 100, null: false, index: { unique: true }
      t.references :parent, foreign_key: { to_table: :categories }, comment: "Parent category, null for a root"
    end

    create_table :customers do |t|
      t.string :name, limit: 100, null: false
      t.string :email, limit: 200, null: false
      t.string :country, limit: 2, null: false
      t.boolean :active, null: false, default: true
      t.date :signed_up_on, null: false
      t.text :notes
    end

    create_table :products, id: false do |t|
      t.string :sku, limit: 20, primary_key: true, comment: "Stock keeping unit"
      t.string :name, limit: 200, null: false
      t.text :description, null: false, default: ""
      t.decimal :price, precision: 10, scale: 2, null: false
      t.references :category, null: false, foreign_key: true
      t.boolean :in_stock, null: false, default: true
      t.json :specs, comment: "Free-form product attributes"
    end

    create_table :orders do |t|
      t.string :number, limit: 20, null: false, index: { unique: true }
      t.references :customer, null: false, foreign_key: true
      t.references :billing_identity, foreign_key: { to_table: :customers },
                   comment: "Customer billed for the order, if not the buyer"
      t.string :status, limit: 20, null: false
      t.decimal :total, precision: 10, scale: 2, null: false
      t.datetime :placed_at, null: false
      t.json :metadata
    end

    create_table :line_items do |t|
      t.references :order, null: false, foreign_key: true
      t.references :product, type: :string, limit: 20, null: false, foreign_key: { primary_key: :sku }
      t.integer :quantity, null: false
      t.decimal :unit_price, precision: 10, scale: 2, null: false
    end
  end
end
