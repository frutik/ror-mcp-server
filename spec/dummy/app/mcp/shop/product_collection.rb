module Shop
  class ProductCollection < RorMcp::Collection
    model Product
    collection_name "product"
    fields :all
    description "A sellable item, identified by its SKU."
    describe :sku, "Stock keeping unit"
    describe :specs, "Free-form product attributes"
    search_fields :name, :description
    instructions "Prices are in EUR. The primary key is the SKU."
  end
end
