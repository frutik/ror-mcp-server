module Shop
  class CustomerCollection < RorMcp::Collection
    model Customer
    collection_name "customer"
    # Whitelist shapes only the schema in :parity mode: without $project rows still carry email and notes.
    fields :id, :name, :country, :active, :signed_up_on

    # Not applied when another collection reaches customers via $lookup (in :parity mode).
    def scope(_context)
      Customer.where(active: true)
    end
  end
end
