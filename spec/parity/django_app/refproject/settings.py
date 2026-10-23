"""Settings for the django-mcp-server reference app used by the parity suite."""
import os
from pathlib import Path
from urllib.parse import urlparse

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = "parity-reference-app-not-secret"
DEBUG = False
ALLOWED_HOSTS = ["*"]

INSTALLED_APPS = [
    "django.contrib.contenttypes",
    "django.contrib.auth",
    "django.contrib.sessions",
    "rest_framework",
    "shop",
    "mcp_server",
]

MIDDLEWARE = [
    "django.middleware.common.CommonMiddleware",
]

ROOT_URLCONF = "refproject.urls"

# SQLite by default; PARITY_DATABASE_URL=postgres://user@host:port/name or mysql://… for the matrix.
_url = urlparse(os.environ.get("PARITY_DATABASE_URL", ""))
if _url.scheme:
    DATABASES = {"default": {
        "ENGINE": {"postgres": "django.db.backends.postgresql", "postgresql": "django.db.backends.postgresql",
                   "mysql": "django.db.backends.mysql"}[_url.scheme],
        "NAME": _url.path.lstrip("/"), "USER": _url.username or "", "PASSWORD": _url.password or "",
        "HOST": _url.hostname or "", "PORT": str(_url.port or ""),
    }}
else:
    DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.sqlite3",
            "NAME": os.environ.get("PARITY_DJANGO_DB", BASE_DIR / "db.sqlite3"),
        }
    }

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
USE_TZ = True
TIME_ZONE = "UTC"
LANGUAGE_CODE = "en-us"

# MCP sessions are stored as Django sessions (database backend).
SESSION_ENGINE = "django.contrib.sessions.backends.db"

DJANGO_MCP_GLOBAL_SERVER_CONFIG = {
    "name": "parity-shop",
    "instructions": "Reference shop server for ror-mcp-server parity tests. "
                    "Query the collections with query_data_collections.",
}

DJANGO_MCP_OUTPUT_RENDERER_CLASSES = [
    "rest_framework.renderers.JSONRenderer",
    "rest_framework_csv.renderers.CSVRenderer",
]

# Bearer token accepted by the second ("analytics") server.
PARITY_ANALYTICS_TOKEN = os.environ.get("PARITY_ANALYTICS_TOKEN", "parity-secret")

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "handlers": {"console": {"class": "logging.StreamHandler"}},
    "loggers": {"mcp_server": {"handlers": ["console"], "level": "WARNING"}},
}
