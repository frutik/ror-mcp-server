# 14. Primary keys are always addressable

Date: 2026-10-24 · Status: Accepted

## Context

Under `:fixed`, a collection's `fields` limits what a pipeline can read, filter, sort or group. The
primary key was an exception nobody had decided on: `_id` and `pk` resolved without the field list,
so a collection declaring `fields :name` hid the key from its rows and schema, yet `$project
{"x": "$_id"}`, `$match {"_id": …}`, `$sort` and `$group` on it all worked. Through a `$lookup`,
`alias.pk` worked and `alias._id` didn't, only because django-mcp-server translates a bare `_id`
and nothing else.

Hiding a primary key can't be made watertight:

- a collection that references this one shows its keys anyway (`order.customer` → `customer_id`);
- `$lookup` joins on the key (`foreignField` is `_id`);
- clients are told that `_id` is the primary key.

Options:

1. Enforce `fields` for `_id`/`pk` too: refuse them unless the key is listed.
2. Declare the key always addressable, document it, and make `alias._id` consistent.

## Decision

Option 2. The primary key is addressable as `_id` or `pk` in every stage, and as `alias._id` or
`alias.pk` after a `$lookup`, whatever `fields` says. `fields` still decides whether rows without
`$project` and the schema show it, and whether its column name (`id`) can be used. The README tells
apps not to publish a model whose primary key is itself sensitive.

## Consequences

- One rule clients can rely on, with no difference between `_id` and `pk`, or between the base and
  a joined collection.
- Leaving the key out of `fields` doesn't anonymize a collection. An app that needs that publishes
  a model (or a database view) without a sensitive key, or aggregates.
- `alias._id` works under `:fixed`. `:parity` keeps django-mcp-server's failure.
- Option 1 stays possible as an opt-in (say `hide_primary_key!`) if an app needs it. It would not
  hide keys that other collections' references show.
