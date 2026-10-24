# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub:
**Security → Report a vulnerability** on
[frutik/ror-mcp-server](https://github.com/frutik/ror-mcp-server/security/advisories/new).
Don't open a public issue for them.

Include what an attacker can do, the affected version, and steps or a pipeline that
reproduces it. You'll get an answer within a week.

## Supported versions

The latest release receives fixes.

## Scope

Of particular interest: anything that lets an MCP client read data a collection doesn't
publish (fields outside `fields`, rows outside `scope`), write through a query or a tool
not declared `writes: true`, run arbitrary SQL, or bypass `authenticate`.
