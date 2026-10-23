# frozen_string_literal: true

module RorMcp
  # `mount RorMcp::Engine, at: "/mcp"` serves the default server, like
  # `path("", include("mcp_server.urls"))` in django-mcp-server.
  # Other servers are mounted with `mount RorMcp.endpoint(:name), at: "…"`.
  # Routes live in config/routes.rb: Rails clears an engine's routes and redraws them from there.
  class Engine < ::Rails::Engine
    engine_name "ror_mcp"

    # Load app/mcp so collections register (autodiscovery of <app>/mcp.py in
    # django-mcp-server). On a development reload the registry is rebuilt and
    # servers pick up the new classes on their next request.
    config.to_prepare do
      RorMcp.registry.clear
      dir = Rails.root.join("app/mcp")
      Rails.autoloaders.main.eager_load_dir(dir.to_s) if dir.directory?
      RorMcp.registry.validate!
    end
  end
end
