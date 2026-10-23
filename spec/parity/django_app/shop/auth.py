from django.conf import settings
from rest_framework.authentication import BaseAuthentication
from rest_framework.exceptions import AuthenticationFailed


class TokenUser:
    is_authenticated = True
    is_active = True
    username = "analytics-token"


class BearerTokenAuthentication(BaseAuthentication):
    """`Authorization: Bearer <PARITY_ANALYTICS_TOKEN>`; anything else → 401."""

    def authenticate(self, request):
        header = request.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return None
        if header[len("Bearer "):] != settings.PARITY_ANALYTICS_TOKEN:
            raise AuthenticationFailed("Invalid token")
        return TokenUser(), None

    def authenticate_header(self, request):
        return "Bearer"
