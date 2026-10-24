# Changelog

## Unreleased

- `:fixed`: a `$lookup` that names a second collection for a reference another `$lookup` already joined is now
  rejected. Such a query used to read one collection's rows under the other's fields, so a more restricted
  collection could expose rows its `scope` excludes. One collection under several aliases still works.
- `:fixed`: a `$lookup` now applies the target collection's `scope` whenever it restricts rows. Scopes that did so
  without a `where`, `joins` or `limit` on the relation (a `from` subquery, `offset`, `having`) were dropped, and the
  join read the whole table.

## 0.1.1 — 2026-10-24

Version bump only; no functional changes since 0.1.0.

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
