# Developing ror-mcp-server

ror-mcp-server is a port of [django-mcp-server](https://github.com/omarbenhamid/django-mcp-server)
(Python). This document covers how the port is built and verified, how to run the tests,
and where the project stands. The full design, decisions and verified assumptions are in
[PLAN.md](PLAN.md).

## Contents

- [Status](#status)
- [Repository layout](#repository-layout)
- [Setup](#setup)
- [Running the tests](#running-the-tests)
- [How the port is verified](#how-the-port-is-verified)
- [Pipeline semantics: `:parity` and `:fixed`](#pipeline-semantics-parity-and-fixed)
- [Coming from django-mcp-server](#coming-from-django-mcp-server)
- [Porting notes](#porting-notes)
- [Releasing](#releasing)

---

## Status

0.1.0 is tagged (`v0.1.0`) and installable from GitHub; it isn't on RubyGems yet.
Milestones from [PLAN.md §8](PLAN.md):

| Milestone | Delivers | Status |
|---|---|---|
| M0 | Gemspec, Django reference app with recorded answers, Rails dummy app, parity client, transport spike | ✅ |
| M1 | `Server`, `Endpoint`, authentication, session stores, `get_server_instructions` | ✅ |
| M2 | Collection DSL, schema generation, `query_data_collections` with `$match $sort $skip $limit $project` | ✅ |
| M3 | `$lookup`, references, multiple servers | ✅ |
| M4 | `$group`, `$text`/`$search`, `extra_filters`, computed fields | ✅ |
| M5 | Toolset DSL, write tools, JSON/CSV/JSONL output, `serialize_with` | ✅ |
| M6 | Safety envelope, `:fixed` semantics, multi-database, sharding, description budget, instrumentation | ✅ |
| M7 | Generators, rake tasks, CI, first release (0.1.0) | ✅ tagged; RubyGems publication pending |

Parity with django-mcp-server: the dummy app gives the reference app's answers on SQLite,
PostgreSQL and MySQL: 119 of 120 checks, plus one documented deviation. The `:fixed`
outputs match their reviewed recordings 120/120 on each database.

Still open: trying Claude Code and MCP Inspector against the endpoint (only the official
Python SDK client has been tested), code reloading in development, and publishing to RubyGems.

---

## Repository layout

| Path | What |
|---|---|
| `lib/ror_mcp/` | The gem. |
| `lib/generators/`, `lib/tasks/` | `ror_mcp:install`/`collection`/`toolset`, rake `ror_mcp:describe`/`check`. |
| `django-mcp-server/` | Git submodule: the library being ported (reference source). |
| `spec/ror_mcp/`, `spec/support/` | Gem specs. `ShopDb` is a small shop schema on any database; `ShardDb` adds two SQLite shards. |
| `spec/parity/django_app/` | Reference Django app: a shop published with django-mcp-server (two servers, tools, CSV, embedded resources, bearer auth). |
| `spec/parity/pipelines/corpus.json` | 107 `tools/call` cases, each tagged with the behaviour it pins. |
| `spec/parity/expected/` | Recorded answers: `django*` from the reference app, `fixed*` from the dummy app, one set per database. |
| `spec/parity/client/` | `mcp_parity.py` (record / check any endpoint, stdlib only), `sdk_smoke.py` (official SDK client), `compare_dbs.py`. |
| `spec/parity/bin/` | `django-server`, `rails-server`, `ci-parity`, `generate-query-tool-text`. |
| `spec/dummy/` | Rails app with the reference app's schema, data and MCP setup, using this gem. |
| `gemfiles/` | Per-Rails-version gemfiles for the CI matrix. |
| `spike/transport/` | M0 findings about the `mcp` gem's transport (the code became `Endpoint`/`Server`). |
| `PLAN.md`, `CLAUDE.md` | Design and decisions; guidance for coding agents. |

---

## Setup

```sh
git clone --recurse-submodules git@github.com:frutik/ror-mcp-server.git
cd ror-mcp-server
bundle install                          # Ruby ≥ 3.2

# Only to run the Django reference app or the Python clients:
python -m venv .venv && .venv/bin/pip install -r spec/parity/requirements.txt
.venv/bin/pip install "psycopg[binary]" mysqlclient   # reference app on PostgreSQL / MySQL
```

On macOS, Homebrew's Ruby lives at `/opt/homebrew/opt/ruby/bin`. The repo root and
`spec/dummy` both install gems into `vendor/bundle`.

---

## Running the tests

### Gem specs

```sh
bundle exec rspec                                     # SQLite in memory
bundle exec rspec spec/ror_mcp/pipeline/compiler_spec.rb:40

RORMCP_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:5432/ror_mcp_test bundle exec rspec
RORMCP_TEST_DATABASE_URL=trilogy://root@127.0.0.1:3306/ror_mcp_test bundle exec rspec

BUNDLE_GEMFILE=gemfiles/rails_7.1.gemfile BUNDLE_PATH=$PWD/vendor/bundle bundle exec rspec   # another Rails
```

### Parity suite

```sh
spec/parity/bin/rails-server &                       # dummy app on :3765 (SQLite, :parity)
.venv/bin/python spec/parity/client/mcp_parity.py check --base-url http://127.0.0.1:3765

DATABASE_URL=postgres://…/ror_mcp_dummy RORMCP_SEMANTICS=fixed spec/parity/bin/ci-parity   # picks the matching recording
```

[spec/parity/README.md](spec/parity/README.md) covers the suite in detail: what is
compared, how to re-record, and the per-database recordings.

### CI

`.github/workflows/ci.yml` runs on every push and pull request:

- **Gem specs:** Ruby 3.2–3.4 × Rails 7.1–8.1, on SQLite, PostgreSQL 16 and MySQL 8.4.
- **Parity:** the dummy app on each database × `:parity`/`:fixed`, checked against the
  recordings, plus `ror_mcp:check`. CI needs no Python dependencies and no Django: the
  recordings are committed.

---

## How the port is verified

The reference Django app (`spec/parity/django_app`) is the specification. It runs
django-mcp-server from the submodule on a shop schema. Its answers to the corpus are
recorded:
- HTTP and session behaviour;
- `tools/list`, including the full `query_data_collections` description;
- 107 `tools/call` cases.

`spec/dummy` has the same schema, the same rows (`spec/parity/fixtures/data.json`) and the
same two servers, built with this gem. It must give the same answers.

Comparison rules (`mcp_parity.py`):
- Content is compared byte for byte.
- Where the reference returns an error, the port only has to return an error from the
  same tool; its wording may differ.
- A trailing `$group` without `$sort` has no defined row order, so its rows are compared
  as a multiset.
- Collection sections in the description are compared in any order. So is the field list
  of "Full text search is supported on…", which Python builds from a `set`.
- pydantic's `title` keys and the Ruby SDK's top-level `"$schema"` are ignored.
- A corpus case marked `parity_deviation` is an intended difference and is reported as
  `dev`. There is one: `$sum: 1` counts with `COUNT(*)`, so models without an `id`
  column work; Django's `Count("id")` fails there.

Django's own answers depend on the database. JSON keys come back reordered from PostgreSQL
`jsonb` and MySQL `JSON`. Decimal averages are exact there, but rounded to 15 significant
digits on SQLite. NULL ordering differs. So each database has its own recording
(`expected/django`, `django-postgresql`, `django-mysql`).

Baseline: the submodule's commit `0599c7d` (v0.5.6 + 16 commits) with Python `mcp==1.30.0`.
`mcp` 2.x breaks django-mcp-server.

---

## Pipeline semantics: `:parity` and `:fixed`

django-mcp-server has behaviours that surprise clients and sometimes leak data.
`config.pipeline_semantics` reproduces them exactly (`:parity`, for clients written
against django-mcp-server) or corrects them (`:fixed`, the default):

| django-mcp-server behaviour | `:parity` | `:fixed` |
|---|---|---|
| No `$project` returns **all** columns, including ones outside `fields` | reproduced | only `fields` + computed |
| Filters, sorts and projections reach columns outside `fields` | reproduced | refused |
| `alias.field` after `$lookup` reaches any column of the joined model | reproduced | only the target collection's `fields` |
| The joined collection's `scope` is ignored | reproduced | applied to the join |
| `$lookup.from` isn't checked against the actual association | accepted | refused, naming the right collection |
| `localField` names containing `_id` mid-word (`billing_identity`) are mangled | reproduced | resolved by reflection |
| References to a published subclass (proxy / STI) are dropped | reproduced | resolved, `ref` names the collection |
| `$sort` with any value other than `1` sorts descending; aliases can't be sorted | reproduced | only `1`/`-1`; aliases allowed |
| `$skip` applies after `$limit` whatever the order; filters after `$limit` fail | reproduced | stages applied in order |
| `$project: {field: 0}` is ignored | reproduced | exclusion supported |
| No default or maximum `$limit` | reproduced | `default_limit` / `max_limit` |
| An empty result returns no content | reproduced | `[]` |

In both modes, `$sum: 1` uses `COUNT(*)` and queries run in the read-only envelope.
`:parity` logs a boot warning for collections whose `fields` don't actually hide columns.

---

## Coming from django-mcp-server

| django-mcp-server | ror-mcp-server |
|---|---|
| `INSTALLED_APPS += ["mcp_server"]` + `path("", include("mcp_server.urls"))` | `gem "ror-mcp-server"` + `mount RorMcp::Engine, at: "/mcp"` |
| `<app>/mcp.py` autodiscovery | `app/mcp/**/*.rb`, loaded at boot |
| `DJANGO_MCP_GLOBAL_SERVER_CONFIG` | `c.default_server name:, instructions:, stateless:` |
| `DjangoMCP(name=…)` + `MCPServerStreamableHttpView.as_view(mcp_server=…)` | `c.server :name, …` + `mount RorMcp.endpoint(:name), at: …` |
| `DJANGO_MCP_AUTHENTICATION_CLASSES` | `c.authenticate { \|request\| … }` (global or per server) |
| `ModelQueryToolset` | `RorMcp::Collection` |
| `model`, `fields`, `exclude_fields`, `search_fields`, `extra_filters` | same names |
| `extra_instructions` | `instructions` |
| `get_queryset()` (with `self.request`) | `scope(context)` |
| model docstring, `help_text`, `choices` | `description`, `describe`, `choice_labels` |
| `output_format`, `output_as_resource` | same names |
| `MCPToolset` (public methods + type hints) | `RorMcp::Toolset` (`tool` + `param` declarations) |
| `@drf_serialize_output(S)` | `serialize_with: S` |
| `DJANGO_MCP_OUTPUT_RENDERER_CLASSES` | `output_format :json / :csv / :jsonl` |
| `DJANGO_MCP_GET_SERVER_INSTRUCTIONS_TOOL` | `c.instructions_tool` |
| `manage.py mcp_inspect` | `bin/rails ror_mcp:describe` |
| `drf_publish_*_mcp_tool` (DRF views as tools) | not in v1 (planned: `publish_action`) |
| `manage.py stdio_server` | not in v1 |
| `@mcp_server.tool()` low-level FastMCP tools | `RorMcp.server(:name).add_tool(MCP::Tool…)` |

Unchanged for clients:
- the tools `query_data_collections` and `get_server_instructions`, and their parameters;
- the description layout and the pipeline syntax;
- the shape of results.

Under `:parity`, responses are byte-identical. Collection names follow Rails
(`line_item`); set `collection_name "lineitem"` to keep Django's lowercase model names.

---

## Porting notes

What it takes to match django-mcp-server byte for byte (details in
[PLAN.md §1A.7](PLAN.md) and [spec/parity/README.md](spec/parity/README.md)):

- **Description text.** `lib/ror_mcp/tools/query_tool_text.rb` is generated from the
  submodule by `spec/parity/bin/generate-query-tool-text`, trailing spaces and typos
  included. Each `$jsonSchema` is printed as a Python `repr` (`RorMcp::PythonRepr`), as
  Django does.
- **Values.** `Renderers::Json` reproduces DRF's `JSONRenderer` (decimals as floats,
  `Z` datetimes, Python float formatting). `Renderers::Csv` reproduces
  djangorestframework-csv. `PyDecimal` keeps Django's quantized decimal text (`499.90`).
- **Tool results.** `Tools::Content` follows FastMCP's conversion. The Ruby SDK turns an
  exception or an unknown tool into a JSON-RPC error, so `Toolset` and the query tool build
  `isError` results themselves.
- **Transport.** The SDK runs stateless with JSON responses, and `Endpoint` applies
  Django's session rules in front of it (see [spike/transport/README.md](spike/transport/README.md)).
  The SDK's DNS-rebinding guard is off; Rails' `config.hosts` covers it.
- **Database differences** are handled per adapter: `REGEXP` function on SQLite,
  `~`/`~*` on PostgreSQL, `REGEXP_LIKE` on MySQL; date parts via `strftime`/`EXTRACT`/`DAYOFWEEK`;
  read-only mode via `PRAGMA query_only` / `SET TRANSACTION READ ONLY`.
- **Not ported:** DRF views as tools, the stdio transport, OAuth.

---

## Releasing

Until 0.1.0 is on RubyGems, apps install from GitHub:

```ruby
gem "ror-mcp-server", github: "frutik/ror-mcp-server", tag: "v0.1.0"
```

To cut a release: bump `lib/ror_mcp/version.rb`, move the CHANGELOG entry under the version,
and check that CI is green. Then tag `vX.Y.Z` and push the tag. Publishing to RubyGems
(`gem build ror-mcp-server.gemspec && gem push ror-mcp-server-X.Y.Z.gem`) needs the owner's
RubyGems account.
