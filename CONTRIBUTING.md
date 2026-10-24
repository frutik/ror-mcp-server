# Contributing

There are two ways to contribute: open a pull request with the change, or open an issue that
describes the problem well enough for someone else to fix it. Both are welcome. An issue that is
easy to reproduce is often worth as much as the patch.

Security problems are the exception: report them privately as described in
[SECURITY.md](SECURITY.md), never in a public issue or pull request.

## Option 1: open a pull request

1. **Fork and branch.** Branch off `main` and use a descriptive name (`fix/lookup-scope`,
   `feature/count-empty-object`). Keep one change per pull request.
2. **Set up.** [DEVELOPMENT.md](DEVELOPMENT.md) covers the setup, the repository layout and how
   to run each test suite.
3. **Write a test first.** A bug fix comes with a spec that fails without the fix. A new feature
   comes with specs that cover it.
4. **Mind both pipeline modes.** If the change touches how queries compile or run, check it under
   both `:parity` and `:fixed` (see
   [Pipeline semantics](DEVELOPMENT.md#pipeline-semantics-parity-and-fixed)). `:parity` must keep
   matching django-mcp-server byte for byte. Corrections go in `:fixed` only.
5. **Run the checks locally:**

   ```sh
   bundle exec rspec
   bundle exec rubocop
   ```

   CI also runs the specs on PostgreSQL and MySQL across the Ruby × Rails matrix, along with the
   parity suite. All of those jobs must pass before a merge.
6. **Update the docs.** Add a line under `## Unreleased` in [CHANGELOG.md](CHANGELOG.md). Update
   [README.md](README.md) if users will notice the change. If the change reverses a design
   decision, update `PLAN.md` and add an ADR in [docs/adr/](docs/adr/).
7. **Open the pull request** against `main`. In the description, cover:
   - **What** changes and **why**: the problem it solves, with a link to the issue if one exists.
   - **How it was tested**: which specs you added and what you ran.
   - **Compatibility**: whether it changes behaviour for existing apps or clients, and in which
     mode (`:parity`, `:fixed` or both).

## Option 2: open an issue

If you can't send a fix, an issue is just as useful, provided someone else can reproduce it from
the issue alone. Include:

- **Versions**: ror-mcp-server (a tag or commit), Ruby, Rails, the database and its version, and
  the `mcp` gem.
- **Configuration**: `pipeline_semantics` (`:parity` or `:fixed`) and any non-default settings
  from `config/initializers/ror_mcp.rb`.
- **The collection or tool involved**: the smallest model and `app/mcp` definition that shows
  the problem.
- **The exact request**: the pipeline you sent to `query_data_collections`, or the tool call and
  its arguments, as JSON.
- **Expected vs. actual**: what you expected and what you got. Paste the full response or error
  and the relevant log lines, not a paraphrase.
- **For parity bugs**: what django-mcp-server returns for the same query, if you can check.

For a feature request, describe the use case first: what you're trying to do, why the current
behaviour doesn't let you, and what you would expect the API to look like. A sketch of the DSL
or the pipeline you would like to write helps.

Issues that can't be reproduced from their description may be closed with a request for the
missing details.
