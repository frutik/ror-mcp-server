# Mirror of the analytics server in spec/parity/django_app/shop/mcp.py.
module Analytics
  class OrderCollection < RorMcp::Collection
    server :analytics
    model Order
    collection_name "order"
    # "customer" is dropped from the schema in :parity mode: only VipCustomer is published here.
    fields :id, :number, :customer, :status, :total, :placed_at
    output_format :csv
  end
end
