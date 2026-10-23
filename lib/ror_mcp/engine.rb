# frozen_string_literal: true

module RorMcp
  # `mount RorMcp::Engine, at: "/mcp"` serves the default server, like
  # `path("", include("mcp_server.urls"))` in django-mcp-server.
  # Other servers are mounted with `mount RorMcp.endpoint(:name), at: "…"`.
  # Routes live in config/routes.rb: Rails clears an engine's routes and redraws them from there.
  class Engine < ::Rails::Engine
    engine_name "ror_mcp"
  end
end
