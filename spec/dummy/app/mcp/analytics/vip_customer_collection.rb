module Analytics
  class VipCustomerCollection < RorMcp::Collection
    server :analytics
    model VipCustomer
    collection_name "vipcustomer"
    fields :id, :name, :country
    output_as_resource true
  end
end
