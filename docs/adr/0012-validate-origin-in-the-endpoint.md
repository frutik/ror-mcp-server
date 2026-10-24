# 12. Validate `Origin` in the endpoint: own origin and a list

Date: 2026-10-24 · Status: Accepted

## Context

The MCP transport spec requires servers to validate the `Origin` header and answer 403 for an invalid
one: otherwise any web page a user visits can drive their browser to call a local or internal MCP
server. The SDK's own guard only accepts loopback `Host` headers, so it is off, and the code and docs
said Rails' `config.hosts` covered both `Host` and `Origin`. It checks `Host` only, and is empty
outside development.

Options for the default:

1. No check unless configured.
2. Accept the server's own origin and a configured list; refuse other origins.
3. Refuse every request that carries `Origin` unless listed.

## Decision

Option 2. `RorMcp::Endpoint` checks `Origin` first, before authentication and for every method
including `DELETE`:

- no `Origin` header: accepted (MCP clients that aren't browsers don't send one);
- the request's own origin (`scheme://host[:port]`, compared case-insensitively): accepted;
- an origin in `allowed_origins` (global, or per server like `authenticate`): accepted;
- anything else, including `null`: `403 Origin not allowed`.

`allowed_origins = :any` turns the check off. Entries that aren't origins raise `ConfigurationError`.

## Consequences

- Cross-site requests from browsers are refused by default, with cookies or not.
- Non-browser clients and same-origin pages need no configuration. Browser apps on another origin
  (a separate front end, a hosted inspector) must be listed.
- Same-origin acceptance trusts the `Host` header, which a DNS-rebinding page controls. `Host`
  stays Rails' job: `config.hosts` has to list the real hosts in production. The README says so.
- Option 1 left the spec's requirement to every app. Option 3 would break same-origin pages for no gain.
