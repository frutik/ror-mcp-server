# 13. Bound sessions and request bodies at the endpoint

Date: 2026-10-24 · Status: Accepted

## Context

For a stateful server, `RorMcp::Endpoint` handles `Mcp-Session-Id` itself; the SDK runs stateless
and its own session protections don't apply. Two ways an unauthenticated client (on a server without
`authenticate`), or any permitted one, could make a process grow without bound:

- **Sessions.** Any parsed object with method `initialize` created a session before the SDK
  validated it, failed ones were never removed, and the `:memory` store had no expiry or cap.
- **Bodies.** To spot `initialize`, the endpoint read and JSON-parsed the whole body with no length
  bound, ahead of the SDK's 4 MiB bounded read.

## Decision

- A session is created only after the SDK answered `initialize` with a result (status 200, a JSON-RPC
  `result`). Errors and refused requests allocate nothing.
- `SessionStore::Memory` gives every session the same lifetime, 14 days by default (the `:cache`
  store's, Django's session age), and holds at most 10,000 (`expires_in:`, `max:`). Because lifetimes
  are equal, insertion order is expiry order: expired and excess sessions are dropped from the front
  as new ones arrive, in constant time per session.
- `max_request_bytes` (default 4 MiB, the SDK's bound) caps POST bodies: `Content-Length` over it, or
  more than that many bytes read (reading at most one past the limit), answers 413 before any
  parsing. The bounded copy is what the SDK reads.

## Consequences

- Memory per process is bounded by `max` sessions and one bounded body per request.
- Past `max`, the oldest session is dropped even if still in use; its client gets 404 and
  initializes again, which the MCP transport spec requires clients to handle. Apps expecting more
  concurrent clients raise `max` or use `:cache`.
- The expiry is fixed from creation, not sliding: a 14-day-old session ends even if active.
- Per-client limits (sessions per token, request rate) are not here; they belong in the app's
  `authenticate` block or a proxy.
