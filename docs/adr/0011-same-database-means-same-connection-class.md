# 11. Same database means same connection class

Date: 2026-10-24 · Status: Accepted

## Context

A `$lookup` join runs on the queried collection's connection, so it is only correct when the target
model lives in the same database. Two copies of a check decided that, one for the schema (whether a
reference is shown) and one for the compiler (whether a join is built). Both compared adapter and
database name, and answered "same" when a connection was missing. Two databases sharing a name
passed: separate PostgreSQL hosts with one database name, or any two SQLite `:memory:` databases. The
join then read the queried database's same-named table, which no collection publishes.

Options:

1. Compare more configuration: host, port, socket, database. Never equal for `:memory:`.
2. Compare the connection owner: the class whose connection a model uses (`connection_specification_name`).

## Decision

Option 2, in one helper, `Schema.same_database?`, which the catalog calls too. Rails files the primary
abstract class (`ApplicationRecord`) under `ActiveRecord::Base`, so the primary database's models,
engine models included, share one owner. Roles, replicas and shards are switches within one owner.
Two connection classes are two databases, even if their configuration names the same one. The
check needs no live connection and has no "unknown, so same" branch.

## Consequences

- A reference the schema shows is one a join accepts: the two can't drift apart.
- Works at boot, before the database exists, and under routed shards.
- Two connection classes configured for the same database can't join. That setup is unusual; the
  error says to put the models under one connection class.
- Option 1 would keep inferring identity from names and settings, which is what failed; it stays
  possible later, as an opt-in, if a real app needs it.
