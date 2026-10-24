# 7. Test `:fixed` with a contract spec; known failures are pending by issue id

Date: 2026-10-24 · Status: Accepted · Implemented in #5

## Context

The security bugs found so far came from parts interacting: lookup binding × join cache, scope shape
× join, scope pagination × the result window. Each class did what its own unit tests would expect.
Per-class unit tests mirror the implementation and wouldn't have found these.

## Decision

`spec/ror_mcp/fixed_contract_spec.rb` checks what `:fixed` promises across a matrix: scope shapes ×
ways a pipeline reaches a collection's rows (direct stages, `$group`, `$lookup` with later stages).

- **Rows:** a client sees only rows ActiveRecord returns for the scope.
- **Fields:** only `fields` can be read, filtered, sorted or grouped.
- **Ceiling:** no query returns more than `max_limit` rows.

Combinations that fail because of an open issue are pending, with the issue's id as the reason.
RSpec fails a pending example once it passes, so a fix also deletes its entries. Narrow unit tests
are kept for single decisions where a failure should point at one method.

## Consequences

- One new scope shape or stage added to the tables is checked against every path, on SQLite,
  PostgreSQL and MySQL.
- The pending list is an honest, executable record of what is still open.
- A failure is database-dependent when the bug only shows under one database's row order. Such an
  entry is pending only on that database (one scope-pagination case only failed on PostgreSQL).
- The matrix is wide (164 examples) but runs in well under a second on SQLite.
