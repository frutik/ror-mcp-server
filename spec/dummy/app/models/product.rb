# A sellable item, identified by its SKU.
class Product < ApplicationRecord
  self.primary_key = "sku"

  belongs_to :category
  has_many :line_items
end
