# 2. A reference joins one collection per query

Date: 2026-10-24 · Status: Accepted · Implemented in #2

## Context

Under `:fixed`, a `$lookup` binds a reference path (`category`, `customer__billing`) to a collection,
and the path's LEFT JOIN reads that collection's scoped rows. The join is built once per path and
cached. A later `$lookup` could bind the same path to a *different* collection over the same model:
field checks then used the second collection while the SQL still read the first one's rows. With two
collections publishing one model under different scopes, a client could read the restricted
collection's fields on rows only the permissive one publishes.

Options:

1. Key joins by path *and* collection, so each binding gets its own aliased join.
2. Refuse to bind a path to a second collection.

## Decision

Option 2. A path joins one collection per query; binding it to a different collection than its join
(or an earlier `$lookup`) raises a `QueryError` naming the collection it already joins. Several
aliases for the same collection still work.

## Consequences

- Closes the bypass with a small change in `Pipeline::Fields` and no new SQL shapes.
- A client can't join one reference to two collections in one query. No useful query needed that:
  without a chain, both aliases already resolved to whichever collection was bound last.
- `:parity` is unaffected; django-mcp-server has no per-collection binding.
- Option 1 stays possible later if a real use for two views of one reference appears.
