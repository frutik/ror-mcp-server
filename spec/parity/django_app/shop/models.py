"""
Reference schema shared with the Rails dummy app (spec/dummy).

Table and column names are fixed with db_table / Django's FK naming so the
Rails app can declare the very same schema. Each model exercises something
the port must reproduce: a self-reference, choices, help_text, a non-`id`
primary key, a JSON column, decimals/dates, an FK whose name contains `_id`
mid-word, and a proxy model.
"""
from django.db import models


class Category(models.Model):
    """A node of the product category tree."""

    name = models.CharField(max_length=100)
    slug = models.CharField(max_length=100, unique=True)
    parent = models.ForeignKey("self", null=True, blank=True, on_delete=models.CASCADE,
                               related_name="children", help_text="Parent category, null for a root")

    class Meta:
        db_table = "categories"


class Customer(models.Model):
    """A person or company that places orders."""

    COUNTRY_CHOICES = [("NL", "Netherlands"), ("BE", "Belgium"), ("DE", "Germany")]

    name = models.CharField(max_length=100)
    email = models.CharField(max_length=200)
    country = models.CharField(max_length=2, choices=COUNTRY_CHOICES)
    active = models.BooleanField(default=True)
    signed_up_on = models.DateField()
    notes = models.TextField(null=True, blank=True)

    class Meta:
        db_table = "customers"


class VipCustomer(Customer):
    """Customers flagged as VIP (proxy model: same table, published on the analytics server)."""

    class Meta:
        proxy = True


class Product(models.Model):
    """A sellable item, identified by its SKU."""

    sku = models.CharField(max_length=20, primary_key=True, help_text="Stock keeping unit")
    name = models.CharField(max_length=200)
    description = models.TextField(blank=True, default="")
    price = models.DecimalField(max_digits=10, decimal_places=2)
    category = models.ForeignKey(Category, on_delete=models.PROTECT, related_name="products")
    in_stock = models.BooleanField(default=True)
    specs = models.JSONField(null=True, blank=True, help_text="Free-form product attributes")

    class Meta:
        db_table = "products"


class Order(models.Model):
    """One row per order placed by a customer."""

    STATUS_CHOICES = [("pending", "Pending"), ("paid", "Paid"), ("shipped", "Shipped"),
                      ("cancelled", "Cancelled")]

    number = models.CharField(max_length=20, unique=True)
    customer = models.ForeignKey(Customer, on_delete=models.PROTECT, related_name="orders")
    # "_id" mid-word: django-mcp-server's localField.replace("_id", "") mangles this name.
    billing_identity = models.ForeignKey(Customer, null=True, blank=True, on_delete=models.PROTECT,
                                         related_name="billed_orders",
                                         help_text="Customer billed for the order, if not the buyer")
    status = models.CharField(max_length=20, choices=STATUS_CHOICES)
    total = models.DecimalField(max_digits=10, decimal_places=2)
    placed_at = models.DateTimeField()
    metadata = models.JSONField(null=True, blank=True)

    class Meta:
        db_table = "orders"


class LineItem(models.Model):
    """A product line within an order."""

    order = models.ForeignKey(Order, on_delete=models.CASCADE, related_name="line_items")
    product = models.ForeignKey(Product, on_delete=models.PROTECT, related_name="line_items")
    quantity = models.IntegerField()
    unit_price = models.DecimalField(max_digits=10, decimal_places=2)

    class Meta:
        db_table = "line_items"
