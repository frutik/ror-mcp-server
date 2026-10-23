# Customers flagged as VIP. Counterpart of Django's proxy model: same table,
# no type column (customers has none, so no STI condition is added).
class VipCustomer < Customer
end
