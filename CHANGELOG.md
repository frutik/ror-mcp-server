# Changelog

## 0.1.0 — 2026-10-24

First release: a Rails port of [django-mcp-server](https://github.com/omarbenhamid/django-mcp-server).

- MCP servers as Rack endpoints on the official `mcp` gem: `RorMcp.configure`, several servers,
  global or per-server `authenticate`, Django-style sessions (`:memory`, `:cache`, custom), stateless servers,
  `get_server_instructions`, `RorMcp::Engine` / `RorMcp.endpoint(:name)`.
- `RorMcp::Collection`: ActiveRecord models published as collections with a field whitelist,
  `scope(context)`, search fields, `extra_filters`, computed fields, `describe` / `choice_labels` /
  `description`, `reference`, `max_limit`, `connects_to`, `routing_field`, CSV / JSONL / embedded-resource output.
- `query_data_collections` with django-mcp-server's description and pipeline syntax: `$match` (incl. `$text`,
  extended operators), `$search`, `$lookup`, `$sort`, `$skip`, `$limit`, `$project`, `$group`.
- `:parity` semantics reproduce django-mcp-server answer for answer (verified against a Django reference app);
  `:fixed` semantics (default) correct its leaks and quirks (PLAN §1B).
- `RorMcp::Toolset`: Ruby methods as tools with declared parameters, FastMCP's result conversion,
  `serialize_with`, `writes: true`.
- Safety envelope: read-only transaction, statement timeout, replica role; default/max limits (`:fixed`);
  description budget; `query.ror_mcp` / `tool.ror_mcp` instrumentation.
- Generators `ror_mcp:install`, `ror_mcp:collection`, `ror_mcp:toolset`; rake `ror_mcp:describe`, `ror_mcp:check`.
- Verified on SQLite, PostgreSQL and MySQL; Ruby 3.2+, Rails 7.1+.
