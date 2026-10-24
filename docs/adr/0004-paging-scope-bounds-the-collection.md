# 4. A paging scope bounds the collection, in both semantics

Date: 2026-10-24 · Status: Accepted · Implemented in #6

## Context

A collection's `scope` may page (`order(:id).limit(100)`, `offset(…)`) to define what it publishes.
Client stages replaced that window: `$limit` and `default_limit` overwrote the scope's limit, `$skip`
its offset, and `$match`/`$sort` ran before it, so `limit(0)` published every row.

## Decision

Before any pipeline stage runs, a scope with `limit` or `offset` becomes a derived table under the
table's own name, keeping its base-table ordering; client stages then work inside it. This applies in
`:parity` too. The `:fixed` window for client `$limit`/`$skip` (`materialize!`) builds the same
derived table and shares the helper.

## Consequences

- The scope's window is the collection's boundary for every stage, `$group` included.
- `:parity` output is unchanged: Django can't filter a sliced queryset at all, so no Django behaviour
  depended on the old result, and a fix for a leak shouldn't depend on the mode.
- Scopes without `limit`/`offset` keep their SQL.
- Sharing the helper also fixed an existing crash: a `$match` or `$sort` after an unordered window
  called `reorder()` with no arguments, which Rails refuses.
