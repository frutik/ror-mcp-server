# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

Pre-M0: the repo holds only `PLAN.md` (the full design) and a stub README. There is no gemspec, Gemfile, code or test suite yet, so there are no build/test commands. Add them here once M0 lands (gemspec, CI matrix, dummy app). `.venv/` is a local Python virtualenv (intended for the Django reference app used by the parity suite); it is not part of the gem.

**`PLAN.md` is the source of truth.** Read the relevant section before implementing anything; when a decision changes, update `PLAN.md` along with the code.

The Python library being ported is vendored as a git submodule at `django-mcp-server/` (fork `gts360/django-mcp-server`; run `git submodule update --init` after cloning). Check behaviour against its source (`mcp_server/djangomcp.py`, `mcp_server/query_tool.py`) instead of guessing. Note: PLAN.md targets 0.5.7, but the submodule is currently at `v0.5.6` + 16 commits (no `v0.5.7` tag exists there), so confirm which commit is the parity baseline before relying on version-specific behaviour.

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

## Testing (planned — PLAN §7)

- Parity suite: a Django reference app (`spec/parity/django_app`, django-mcp-server 0.5.7) and the Rails dummy app (`spec/dummy`) share one schema and fixtures; a shared pipeline corpus must yield identical JSON in `:parity` mode, with separate expected outputs for `:fixed`.
- One regression spec per "problem in practice" row of PLAN §3.
- Matrix: Postgres (primary), MySQL, SQLite × Rails 7.1/7.2/8.x × Ruby 3.2–3.4.

Milestones and open decisions are in PLAN §8–§10; don't assume a §9 decision has been made unless the code or PLAN says so.
