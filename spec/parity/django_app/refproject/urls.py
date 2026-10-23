from django.urls import include, path
from rest_framework.permissions import IsAuthenticated

from mcp_server.views import MCPServerStreamableHttpView
from shop.auth import BearerTokenAuthentication
from shop.mcp import analytics_server

urlpatterns = [
    # Default server: no auth, stateful (Django sessions), mounted at /mcp.
    path("", include("mcp_server.urls")),
    # Second server: bearer auth, stateless.
    path(
        "mcp/analytics",
        MCPServerStreamableHttpView.as_view(
            mcp_server=analytics_server,
            authentication_classes=[BearerTokenAuthentication],
            permission_classes=[IsAuthenticated],
        ),
    ),
]
