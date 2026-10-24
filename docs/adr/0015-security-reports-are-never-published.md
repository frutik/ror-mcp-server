# 15. Security review reports are never published

Date: 2026-10-24 · Status: Accepted · Supersedes [0009](0009-security-findings-stay-private-until-fixed.md)

## Context

ADR 0009 kept a security review's report and reproduction script out of the repository while findings
were open, and allowed publishing them once every finding was fixed or accepted. All findings of the
first review are now resolved, in 0.1.2.

## Decision

Security review reports and their reproduction scripts are never published: not in the repository,
not as an advisory, not after the findings are fixed. They stay local (`.gitignore`).

What is public about a finding is its fix: the pull request, its regression tests (the contract spec
and focused specs), the CHANGELOG entry, and an ADR when the fix is a decision. Vulnerability reports
from others follow SECURITY.md.

## Consequences

- The record of what was wrong and why lives in fix PRs, CHANGELOG and ADRs, written for users of
  the gem, not in an attacker-oriented report.
- Reproductions survive as specs that assert the secure behaviour, not as scripts that demonstrate
  the vulnerable one.
- The `.gitignore` entries stay permanently.
