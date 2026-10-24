# 8. Differences from django-mcp-server live in DEVELOPMENT.md

Date: 2026-10-24 · Status: Accepted

## Context

Fixes to `:fixed` add client-visible differences from django-mcp-server. A separate
"differences from the Django version" document was considered.

## Decision

No new document. Differences stay where they are already listed:

- the "Pipeline semantics: `:parity` and `:fixed`" table in DEVELOPMENT.md (what clients see),
- "Coming from django-mcp-server" in DEVELOPMENT.md (API mapping),
- `PLAN.md` §1B (the design view).

A client-visible change to `:fixed` adds a row to the DEVELOPMENT.md table. README.md keeps its single
mention of the port.

## Consequences

- One list to keep current, not two that drift apart.
- Readers coming from Django look in DEVELOPMENT.md, which the README links to.
