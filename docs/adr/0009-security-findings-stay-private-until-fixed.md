# 9. Security findings stay out of the repository until fixed

Date: 2026-10-24 · Status: Superseded by [0015](0015-security-reports-are-never-published.md)

## Context

The repository is public. A security review produced a findings report and a reproduction script.
Committing them while findings are open would publish working reproductions of unfixed issues.

## Decision

- Review reports and reproductions stay out of the repository (`.gitignore`) while any finding they
  describe is open.
- Each fix lands as a normal pull request with regression tests and a CHANGELOG entry.
- Open issues are tracked by id in the contract spec's pending list (ADR 0007).
- Once every finding is fixed or explicitly accepted, the report may be published, either in the
  repository or as a GitHub security advisory. Vulnerability reports from others follow SECURITY.md.

## Consequences

- Fix PRs are public as they land, so each fixed issue is disclosed with its fix. Releasing soon
  after merging keeps the window short.
- The ignore entries show that a report exists, though not what it says.
