# frozen_string_literal: true

require_relative "lib/ror_mcp/version"

Gem::Specification.new do |spec|
  spec.name = "ror-mcp-server"
  spec.version = RorMcp::VERSION
  spec.authors = ["Andrew Kornilov"]
  spec.email = ["frutik@gmail.com"]

  spec.summary = "Mount MCP servers in a Rails app and publish ActiveRecord models as queryable collections."
  spec.description = <<~DESC
    A Rails port of django-mcp-server: MCP servers mounted as Rack endpoints, ActiveRecord
    models published as collections queried with a MongoDB-style aggregation pipeline,
    and plain Ruby methods published as MCP tools.
  DESC
  spec.homepage = "https://github.com/frutik/ror-mcp-server"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "config/routes.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  # Official MCP Ruby SDK, kept below 2.0: the transport API moves fast (spike/transport/README.md).
  spec.add_dependency "mcp", "~> 1.8"
  spec.add_dependency "rack", ">= 2.2"
  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "railties", ">= 7.1"
end
