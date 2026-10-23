# A sellable item, identified by its SKU.
class Product < ApplicationRecord
  self.primary_key = "sku"
  # Django keeps defaults in Python; MySQL can't store one on a TEXT column.
  attribute :description, default: ""

  belongs_to :category
  has_many :line_items
end
