module Shop
  class OrderCollection < RorMcp::Collection
    model Order
    collection_name "order"
    fields :all
    exclude_fields :metadata
    extra_filters :icontains, :startswith, :year
    instructions "Latest order = highest id."
  end
end
