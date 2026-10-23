# A person or company that places orders.
class Customer < ApplicationRecord
  enum :country, { "NL" => "NL", "BE" => "BE", "DE" => "DE" }, validate: true

  has_many :orders
  has_many :billed_orders, class_name: "Order", foreign_key: :billing_identity_id
end
