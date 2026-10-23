module Shop
  class ProductCollection < RorMcp::Collection
    model Product
    collection_name "product"
    fields :all
    search_fields :name, :description
    instructions "Prices are in EUR. The primary key is the SKU."
  end
end
