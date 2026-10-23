module Shop
  class OrderCollection < RorMcp::Collection
    model Order
    collection_name "order"
    fields :all
    description "One row per order placed by a customer."
    describe :billing_identity, "Customer billed for the order, if not the buyer"
    exclude_fields :metadata
    extra_filters :icontains, :startswith, :year
    instructions "Latest order = highest id."
  end
end
