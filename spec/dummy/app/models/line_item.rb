# A product line within an order.
class LineItem < ApplicationRecord
  belongs_to :order
  belongs_to :product
end
