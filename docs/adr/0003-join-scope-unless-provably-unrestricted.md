# 3. A `$lookup` joins the target's scope unless it is provably every row

Date: 2026-10-24 · Status: Accepted · Implemented in #4

## Context

Under `:fixed`, a `$lookup` applies the target collection's `scope` by joining it as a subquery. To
keep SQL simple, the compiler joined the bare table when the scope looked trivial: no `where`, no
`joins`, no `limit`. That test lists what a restriction might look like, and missed the rest: a `FROM`
subquery, `offset`, `having`. The join then read rows the target's scope excludes.

Options:

1. Extend the list of relation parts that count as a restriction.
2. Prove the opposite: the scope is unrestricted only if its SQL, less `ORDER BY`, equals the unscoped table's.
3. Always join a subquery.

## Decision

Option 2. Anything that changes the SQL counts as a restriction, so the subquery is used. That includes
default scopes, STI type conditions, and relation features Rails adds later.

## Consequences

- Fails safe: an unknown relation feature costs a subquery, never a leak.
- Unrestricted and ordering-only scopes keep the bare-table join, so their SQL is unchanged.
- Generating SQL for the comparison costs one `to_sql` per joined collection per query, which is negligible next to the query.
- Option 3 was simpler but changed the SQL of every lookup for no gain.
