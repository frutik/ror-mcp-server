# Mirrors spec/parity/django_app/refproject/settings.py + urls.py.

RorMcp.configure do |c|
  c.pipeline_semantics = :parity

  c.default_server name: "parity-shop",
                   instructions: "Reference shop server for ror-mcp-server parity tests. " \
                                 "Query the collections with query_data_collections."

  c.server :analytics, name: "parity-analytics",
                       instructions: "Reporting server. Orders come back as CSV.",
                       stateless: true,
                       authenticate: ->(request) {
                         token = ENV.fetch("PARITY_ANALYTICS_TOKEN", "parity-secret")
                         request.authorization.to_s == "Bearer #{token}" ? { token: :analytics } : nil
                       }
end
