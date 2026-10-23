# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

M1 done (M0's CI matrix still open). `lib/ror_mcp/` has Configuration, Server (wraps `MCP::Server`), Endpoint (Rack: auth → Django session rules → SDK transport, stateless + JSON), SessionStore::{Memory,Cache} and Engine. The SDK findings behind that design are in `spike/transport/README.md`. Next is M2: Collection DSL, schema, `query_data_collections`. The parity harness defines "done": a reference Django app, its recorded golden output, and the Rails dummy app that must reproduce it (details: `spec/parity/README.md`).

## Commands

```sh
# Gem (repo root); Ruby >= 3.2 on PATH, gems install into vendor/bundle
bundle install
bundle exec rspec                                        # all specs (spec/dummy and spec/parity are excluded)
bundle exec rspec spec/ror_mcp/endpoint_spec.rb:90      # one example (line of an `it`)

# Python side (reference app + clients); .venv is git-ignored
python -m venv .venv && .venv/bin/pip install -r spec/parity/requirements.txt
spec/parity/bin/django-server            # reset DB from fixture, serve reference app on :8765

# Rails side: needs Ruby >= 3.2 (system Ruby is 2.6; Homebrew's is at /opt/homebrew/opt/ruby/bin)
PATH=/opt/homebrew/opt/ruby/bin:$PATH spec/parity/bin/rails-server   # reset DB, serve spec/dummy on :3765

# Verification
.venv/bin/python spec/parity/client/compare_dbs.py                                       # both DBs identical
.venv/bin/python spec/parity/client/mcp_parity.py check --base-url http://127.0.0.1:3765  # Rails vs golden
.venv/bin/python spec/parity/client/mcp_parity.py check --base-url http://127.0.0.1:3765 --only group-null,lookup-basic
.venv/bin/python spec/parity/client/mcp_parity.py check --http-only --base-url http://127.0.0.1:3765  # HTTP/session rules only (M1 gate)
.venv/bin/python spec/parity/client/sdk_smoke.py --base-url http://127.0.0.1:3765         # official MCP SDK client
.venv/bin/python spec/parity/client/mcp_parity.py record   # re-record golden from :8765, then review the diff
```

Both the repo root and `spec/dummy` install gems into `vendor/bundle` (the Homebrew gem dir isn't writable from the sandbox). `spec/dummy` loads the gem via `path: "../.."`. Its `app/mcp`, initializer and routes stay dormant until `RorMcp::Collection` is defined (M2).

**`PLAN.md` is the source of truth.** Read the relevant section before implementing anything; when a decision changes, update `PLAN.md` along with the code.

The Python library being ported is vendored as a git submodule at `django-mcp-server/` (fork `gts360/django-mcp-server`; run `git submodule update --init` after cloning). Check behaviour against its source (`mcp_server/djangomcp.py`, `mcp_server/query_tool.py`) instead of guessing. The parity baseline is the submodule's pinned commit (`0599c7d`, v0.5.6 + 16 commits; no `v0.5.7` tag exists) with `mcp==1.30.0`. `mcp` 2.x breaks django-mcp-server.

## What this is

`ror-mcp-server` (require `ror_mcp_server`, namespace `RorMcp`) is a Ruby gem that ports [django-mcp-server](https://github.com/omarbenhamid/django-mcp-server) **0.5.7** to Rails: mount MCP servers inside a Rails app, publish ActiveRecord models as queryable *collections* through a MongoDB-style aggregation pipeline, and publish plain Ruby methods as MCP tools. Built on the official `mcp` gem; Rails >= 7.1, Ruby >= 3.2.

## Architecture (planned — see PLAN.md §1B, §4–§6)

Request flow: `RorMcp::Endpoint` (pure Rack app: auth block → `Mcp-Session-Id` handling via a pluggable `SessionStore` → `mcp` SDK, JSON responses only, no SSE) → `RorMcp::Server` (wraps `MCP::Server`) → either a `Toolset` tool, `get_server_instructions`, or the single `query_data_collections` tool → `RorMcp::Executor` (collection → `scope(context)` → `Pipeline::Compiler` → run inside the safety envelope → renderer).

Key pieces and how they relate:
- **Boot**: `RorMcp::Engine` eager-loads `app/mcp/**` and builds servers *after* boot (and on dev reload). `RorMcp::Registry` keys collections by `[server, collection_name]` and toolsets by `[server, tool_name]` — never by class name; duplicates raise at boot; `abstract!` classes are skipped.
- **Collections** (`RorMcp::Collection` DSL): `fields` is required (or `fields :all`); `RorMcp::Schema` turns them into the same `$jsonSchema` shape django-mcp-server emits. References resolve via `belongs_to` reflection to a collection on the *same server*.
- **Pipeline compiler** (`RorMcp::Pipeline::Compiler` + `Match`/`Lookup`/`Project`/`Group`): compiles `$match $text/$search $lookup $sort $skip $limit $project $group` to Arel/ActiveRecord. It has two modes:
  - `:parity` reproduces every 0.5.7 quirk (PLAN §1A.6) so output can be diffed byte-for-byte against Django.
  - `:fixed` (default for new apps) corrects the quirks listed in the PLAN §1B deviations table.
  When touching compiler behaviour, check both modes against that table.
- **Safety envelope** (both modes): read-only transaction, `while_preventing_writes`, statement timeout, default/max limit.
- **Tool description text** (preamble, DSL spec wording, per-collection layout, tool names) must match django-mcp-server so existing client prompts transfer.
- Output rows match Django's `QuerySet.values()` + DRF `JSONRenderer` encoding (PK as `id`, FKs as `<name>_id`, DRF date/decimal/UUID formats).

## Parity harness (PLAN §7, `spec/parity/README.md`)

- The reference app is the spec. `spec/parity/django_app/shop/mcp.py` and `spec/dummy/app/mcp/**` (+ `config/initializers/ror_mcp.rb`) are mirrors: change both together, keep table/column names identical, and re-record the golden files.
- `spec/dummy/app/mcp` uses the planned `RorMcp` DSL and is dormant (autoload-ignored, routes not mounted) until `RorMcp::Collection` exists. When building M1/M2 components, make the dummy app's code real instead of changing it to fit.
- `expected/django/` is generated output. Never hand-edit it; re-record from a fresh `bin/django-server`. Recordings depend on `PYTHONHASHSEED=0`.
- Collection names follow Django (`lineitem`, `vipcustomer`), so the Rails mirror pins them with `collection_name`.
- Quirks the port must reproduce beyond the source reading are listed in PLAN §1A.7.
- Still planned: one regression spec per PLAN §3 row, and the Postgres/MySQL × Rails × Ruby matrix (the parity DBs are SQLite today).

Milestones and open decisions are in PLAN §8–§10; don't assume a §9 decision has been made unless the code or PLAN says so.
