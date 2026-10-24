# 6. RuboCop, configured to the existing style

Date: 2026-10-24 · Status: Accepted · Implemented in #3

## Context

The project had no linter. RuboCop's defaults reported 2,511 offenses, mostly its single-quote rule
against code written with double quotes, plus method-size limits the compiler can't meet without
needless indirection. A trial autocorrect also made code worse: modifier `if`s past 140 columns,
reflowed long lines, dropped trailing commas, and one "fix" (`each_key` on an array of pairs) that
would have broken `$group`.

## Decision

Adopt RuboCop and rubocop-rspec, with `.rubocop.yml` matching the code as written: double quotes,
160 columns without line-length autocorrect, no Metrics cops, and trailing commas and guard style left
to the author. RSpec cops apply to `spec/**/*_spec.rb` only, because `describe :field` in
`spec/dummy/app/mcp` is the collection DSL. Lint and security cops stay fully on. CI runs it on every
pull request.

## Consequences

- Catches real bugs (Lint), not taste. A tightened style would need its own decision and a separate,
  mechanical change.
- Autocorrect output still needs review; the config disables the cops whose corrections were harmful.
- Making the check required for merging is a separate repository setting, not yet done.
