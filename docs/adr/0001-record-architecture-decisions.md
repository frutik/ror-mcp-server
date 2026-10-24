# 1. Record architecture decisions

Date: 2026-10-24 · Status: Accepted

## Context

`PLAN.md` describes what the gem does and, in §9, the decisions taken before M0. Later decisions,
mostly from fixing a security audit, lived only in commit messages and pull requests, where the
alternatives and their costs are hard to find again.

## Decision

Record decisions as ADRs in `docs/adr/`, one file each, in the Context / Decision / Consequences
format. `PLAN.md` remains the specification; an ADR says why, and the change that implements it
updates `PLAN.md` too.

## Consequences

- A reviewer can find why a rule exists (for example, why a `$lookup` is refused) without reading history.
- One more file per significant decision. Small, reversible choices don't need one.
