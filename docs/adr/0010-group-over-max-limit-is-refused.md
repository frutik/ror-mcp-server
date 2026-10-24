# 10. A `$group` over `max_limit` groups is refused, not cut short

Date: 2026-10-24 · Status: Accepted

## Context

Under `:fixed`, `max_limit` bounds the rows a query returns, but `$group` output had no bound: grouping
by a unique field, or grouping without accumulators (one row per record), returned the whole
collection. `max_limit` also applied only when another limit was set, so `default_limit = nil`
removed it.

Ordinary queries are paged: without `$limit` they get `default_limit` rows, and a client asks for more
with `$skip`/`$limit`. `$group` must be the last stage, so its output can't be paged.

Options for a `$group` with more than `max_limit` groups:

1. Return the first `max_limit` groups.
2. Refuse the query with an error that says how to narrow it.
3. Cap the input rows before grouping.

## Decision

Option 2, `:fixed` only. The query fetches `max_limit + 1` grouped rows; more than `max_limit` is a
`QueryError` ("narrow it with a $match first, or group by fewer values"). Separately, `max_limit`
caps ordinary queries even when `default_limit` is nil.

## Consequences

- A client never gets an incomplete aggregate that looks complete. Option 1 would hand a model
  truncated totals with no sign anything is missing. Option 3 would change the totals themselves.
- The database still groups everything before the limit; the bound is on what is loaded and
  serialized. `statement_timeout` bounds the database side.
- Queries that worked before can now fail, when they produced more than `max_limit` groups (1000 by
  default). They were returning more rows than any other query is allowed.
- `:parity` keeps django-mcp-server's unbounded `$group`.
