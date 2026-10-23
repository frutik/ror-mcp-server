module Shop
  class LineItemCollection < RorMcp::Collection
    model LineItem
    collection_name "lineitem"
    fields :all
  end
end
