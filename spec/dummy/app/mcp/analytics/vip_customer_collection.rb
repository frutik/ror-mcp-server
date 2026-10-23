module Analytics
  class VipCustomerCollection < RorMcp::Collection
    server :analytics
    model VipCustomer
    collection_name "vipcustomer"
    fields :id, :name, :country
    description "Customers flagged as VIP (proxy model: same table, published on the analytics server)."
    choice_labels :country, "NL" => "Netherlands", "BE" => "Belgium", "DE" => "Germany"
    output_as_resource true
  end
end
