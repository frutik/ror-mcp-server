module Shop
  class ShopTools < RorMcp::Toolset
    tool :add, description: "Add two integers." do
      param :a, :integer, required: true
      param :b, :integer, required: true
    end

    def add(a:, b:)
      a + b
    end

    tool :customer_order_count, description: "Number of orders placed by one customer." do
      param :customer_id, :integer, required: true
    end

    def customer_order_count(customer_id:)
      { customer_id: customer_id, orders: Order.where(customer_id: customer_id).count }
    end

    # Django: @drf_serialize_output(OrderSerializer) → decimals as strings, datetimes ISO 8601.
    tool :latest_order, description: "The order with the highest id, serialized with a DRF serializer.",
                        serialize_with: ->(order) {
                          { id: order.id, number: order.number, status: order.status, total: format("%.2f", order.total),
                            placed_at: order.placed_at.utc.iso8601, customer: order.customer_id }
                        }

    def latest_order
      Order.order(id: :desc).first
    end

    tool :explode, description: "Always fails; exercises the tool error path." do
      param :reason, :string, required: true
    end

    def explode(reason:)
      raise ArgumentError, "exploded: #{reason}"
    end
  end
end
