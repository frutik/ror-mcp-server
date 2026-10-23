"""
MCP publication of the reference shop. spec/dummy/app/mcp mirrors this file.

Default server (/mcp, stateful, no auth):
  collections category, customer, product, order, lineitem + ShopTools
Analytics server (/mcp/analytics, stateless, bearer auth):
  collections order (CSV output), vipcustomer (embedded resource) + AnalyticsTools
"""
from django.db.models import Count, Sum

from mcp_server import MCPToolset, ModelQueryToolset, drf_serialize_output
from mcp_server.djangomcp import DjangoMCP

from .models import Category, Customer, LineItem, Order, Product, VipCustomer
from .serializers import OrderSerializer

analytics_server = DjangoMCP(
    name="parity-analytics",
    instructions="Reporting server. Orders come back as CSV.",
    stateless=True,
)


# --- default server -------------------------------------------------------

class CategoryCollection(ModelQueryToolset):
    model = Category


class CustomerCollection(ModelQueryToolset):
    model = Customer
    # Whitelist shapes only the schema: without $project the rows still carry email and notes.
    fields = ["id", "name", "country", "active", "signed_up_on"]

    def get_queryset(self):
        # Not applied when another collection reaches customers via $lookup.
        return super().get_queryset().filter(active=True)


class ProductCollection(ModelQueryToolset):
    model = Product
    search_fields = ["name", "description"]
    extra_instructions = "Prices are in EUR. The primary key is the SKU."


class OrderCollection(ModelQueryToolset):
    model = Order
    exclude_fields = ["metadata"]
    extra_filters = ["icontains", "startswith", "year"]
    extra_instructions = "Latest order = highest id."


class LineItemCollection(ModelQueryToolset):
    model = LineItem


class ShopTools(MCPToolset):
    def add(self, a: int, b: int) -> int:
        """Add two integers."""
        return a + b

    def customer_order_count(self, customer_id: int) -> dict:
        """Number of orders placed by one customer."""
        return {"customer_id": customer_id, "orders": Order.objects.filter(customer_id=customer_id).count()}

    @drf_serialize_output(OrderSerializer)
    def latest_order(self):
        """The order with the highest id, serialized with a DRF serializer."""
        return Order.objects.order_by("-id").first()

    def explode(self, reason: str) -> str:
        """Always fails; exercises the tool error path."""
        raise ValueError(f"exploded: {reason}")


# --- analytics server -----------------------------------------------------

class AnalyticsOrderCollection(ModelQueryToolset):
    mcp_server = analytics_server
    model = Order
    fields = ["id", "number", "customer", "status", "total", "placed_at"]
    output_format = "csv"


class AnalyticsVipCustomerCollection(ModelQueryToolset):
    mcp_server = analytics_server
    model = VipCustomer
    fields = ["id", "name", "country"]
    output_as_resource = True


class AnalyticsTools(MCPToolset):
    mcp_server = analytics_server

    def revenue_by_status(self) -> list[dict]:
        """Order count and revenue per status."""
        rows = Order.objects.values("status").annotate(orders=Count("id"), revenue=Sum("total")).order_by("status")
        return [{"status": r["status"], "orders": r["orders"], "revenue": f"{r['revenue']:.2f}"} for r in rows]

    def line_item_count(self) -> int:
        """Total number of line items."""
        return LineItem.objects.count()
