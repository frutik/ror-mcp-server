# Architecture decision records

Why the project is the way it is. [`PLAN.md`](../../PLAN.md) stays the specification of what the gem
does; an ADR records a decision, the alternatives, and what it costs. Add one when a choice is hard
to reverse or would surprise the next person to touch the code, and update `PLAN.md` with it.

Format: Context, Decision, Consequences. Number in order; never renumber. A decision that changes
gets a new ADR that supersedes the old one, and the old one's status says so.

| # | Decision | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | Accepted |
| [0002](0002-one-collection-per-reference.md) | A reference joins one collection per query | Accepted |
| [0003](0003-join-scope-unless-provably-unrestricted.md) | A `$lookup` joins the target's scope unless it is provably every row | Accepted |
| [0004](0004-paging-scope-bounds-the-collection.md) | A paging scope bounds the collection, in both semantics | Accepted |
| [0005](0005-read-only-tools-fail-closed.md) | Read-only tools fail closed and guard each declared database | Accepted |
| [0006](0006-rubocop-to-the-existing-style.md) | RuboCop, configured to the existing style | Accepted |
| [0007](0007-fixed-semantics-contract-spec.md) | Test `:fixed` with a contract spec; known failures are pending by issue id | Accepted |
| [0008](0008-django-differences-in-development-md.md) | Differences from django-mcp-server live in DEVELOPMENT.md | Accepted |
| [0009](0009-security-findings-stay-private-until-fixed.md) | Security findings stay out of the repository until fixed | Accepted |
| [0010](0010-group-over-max-limit-is-refused.md) | A `$group` over `max_limit` groups is refused, not cut short | Accepted |
