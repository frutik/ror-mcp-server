module Shop
  class LineItemCollection < RorMcp::Collection
    model LineItem
    collection_name "lineitem"
    fields :all
    description "A product line within an order."
  end
end
