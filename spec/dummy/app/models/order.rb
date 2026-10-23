# One row per order placed by a customer.
class Order < ApplicationRecord
  enum :status, { pending: "pending", paid: "paid", shipped: "shipped", cancelled: "cancelled" }, validate: true

  belongs_to :customer
  # "_id" mid-word: django-mcp-server's localField.replace("_id", "") mangles this name.
  belongs_to :billing_identity, class_name: "Customer", optional: true
  has_many :line_items
end
