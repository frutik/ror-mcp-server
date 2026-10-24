# 5. Read-only tools fail closed and guard each declared database

Date: 2026-10-24 · Status: Accepted · Implemented in #7

## Context

Tools not declared `writes: true` run in the read-only envelope: Rails' `while_preventing_writes`,
plus a rolled-back transaction with database-level read-only mode and a statement timeout. Two gaps:

- When `ActiveRecord::Base` had no connection pool, the envelope returned early and the tool ran with
  no guard at all, although Rails' write check needs no connection.
- The transaction and database-level guards covered only `Base`'s connection. On another database,
  a read-only tool had only Rails' check, which inspects SQL text and can be switched off by the tool.

## Decision

- Rails' write check always applies. Without a pool, only the transaction and database guard are skipped.
- Toolsets declare the other databases their tools use, `databases AnalyticsRecord, …` (connection
  classes). Read-only tools get the rolled-back read-only transaction on each one too.
- A declared database without a connection fails the call; a declared class that shares `Base`'s
  connection is covered by `Base`'s guard.
- The name is `databases`, not `connects_to`, which on collections means role and shard.

## Consequences

- The guard never silently disappears. The failure mode is an error, not an unguarded write.
- Multi-database apps opt in per toolset; apps with one database change nothing.
- The declaration has to be kept up to date. A tool that starts using another database without
  declaring it has Rails' check only, as before.
- Write prevention must stay inside `connected_to(role:)`, which resets `prevent_writes` for its class.
