# Parity suite

The Django reference app is the specification. It runs django-mcp-server from
the `django-mcp-server/` submodule (commit `0599c7d`, v0.5.6 + 16 commits). Its
answers to a fixed corpus are recorded as golden files. The Rails dummy app
(`spec/dummy`) has the same schema, the same data and the same MCP publication,
and must give the same answers.

```
fixtures/data.json        shared rows, loaded by both apps
django_app/               reference app (shop/models.py, shop/mcp.py)
../dummy/                 Rails mirror (app/models, app/mcp, config/initializers/ror_mcp.rb)
pipelines/corpus.json     107 tools/call cases, each tagged with the behaviour it pins
expected/django/          golden output recorded from the reference app
client/mcp_parity.py      raw HTTP/JSON-RPC client: record | check
client/sdk_smoke.py       same endpoints through the official MCP Python SDK client
client/compare_dbs.py     both apps' SQLite DBs hold the same schema and rows
bin/django-server         reset DB from the fixture, serve on :8765
bin/rails-server          reset DB from the fixture, serve on :3765
```

## Running

```sh
python -m venv .venv && .venv/bin/pip install -r spec/parity/requirements.txt
spec/parity/bin/django-server &                       # :8765
PATH=/opt/homebrew/opt/ruby/bin:$PATH spec/parity/bin/rails-server &   # :3765

.venv/bin/python spec/parity/client/compare_dbs.py
.venv/bin/python spec/parity/client/mcp_parity.py check                                   # Django vs golden (must be 100%)
.venv/bin/python spec/parity/client/mcp_parity.py check --base-url http://127.0.0.1:3765  # Rails vs golden
.venv/bin/python spec/parity/client/mcp_parity.py check --base-url http://127.0.0.1:3765 --only lookup-basic,group-null
.venv/bin/python spec/parity/client/sdk_smoke.py --base-url http://127.0.0.1:3765
```

Re-record the golden files only when the reference app, the corpus or the
submodule changes: `mcp_parity.py record` (against a freshly started
`bin/django-server`). Then review the diff of `expected/django/`.

## What is compared

- **HTTP/session** (`expected/django/http.json`): 400 without a session, 404
  for an unknown or deleted session, `Mcp-Session-Id` issued on `initialize`,
  202 for notifications, stateless second server, 401 + `WWW-Authenticate:
  Bearer` without a valid token.
- **tools/list** per server: tool names, descriptions (including the full
  `query_data_collections` text) and input schemas, ignoring pydantic `title` keys.
- **Every corpus case**: the `content` array, byte for byte. Use `--semantic`
  to accept JSON that only differs in formatting. When the reference returns
  an error, the port only has to return an error too; its wording may differ.
  `structuredContent` is not compared.

The golden files pin `:parity` semantics. `:fixed` mode (PLAN §1B) will need
its own expected directory.

## Port constraints the reference app revealed

These aren't in PLAN §1A yet, and the golden files depend on them:

- The `$jsonSchema` in the `query_data_collections` description is Python
  `repr` (single quotes, `True`, `None`) inside a ```` ```json ```` fence, not JSON.
- "Full text search is supported on the following fields: …" joins a Python
  `set`, so its order is arbitrary. The checker compares that line
  order-insensitively. `bin/django-server` pins `PYTHONHASHSEED=0` so the
  golden files are stable.
- `BigAutoField` PKs come out as `bsonType: "int"` (`IntegerField` matches first).
- `$group` by a single field puts the key under the field's name (`"status"`),
  not under `_id`. Alias paths become nested objects (`{"p": {"category": 2}}`).
- `$and`/`$or`/`$nor` return early, so other keys in the same `$match` object
  are silently dropped (`match-or-ignores-siblings`).
- `$sort` doesn't translate `alias.field` and fails (`sort-on-alias`).
- Decimals render as JSON floats in query results (`499.9`). DRF serializers
  (tool output) render them as strings (`"1398.00"`). Averages carry SQLite
  float noise (`1016.16333333333`).
- CSV output sorts columns alphabetically, flattens JSON columns
  (`metadata.channel`), and prints datetimes as `2024-11-26 12:23:00+00:00`.
- Custom tools: a `dict` return is pretty-printed JSON (indent 2), and a
  `list` return becomes one text content per element.
- A Django column can't be called `attributes` in Rails (it clashes with
  `ActiveRecord::Base#attributes`), so the JSON column is `products.specs`.
- SQLite has no column comments, so Django `help_text` has no Rails
  counterpart on SQLite. Schema descriptions need another source there (or Postgres).
