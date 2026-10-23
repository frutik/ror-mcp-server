# M0 transport spike

Throwaway code that answers PLAN §10.1 (A1–A10) before `RorMcp::Endpoint` (C5)
and `RorMcp::Server` (C4) are written in M1. `spike.rb` mounts two `mcp` gem
servers shaped like the reference app's (`/mcp` stateful, `/mcp/analytics`
stateless + bearer) in a plain Rack app.

```sh
bundle exec rspec spec/spike                                   # 19 examples pin the findings below
bundle exec rackup spike/transport/config.ru -p 3766 -o 127.0.0.1
.venv/bin/python spec/parity/client/mcp_parity.py check --http-only --base-url http://127.0.0.1:3766   # 11/11
```

## Result

The reference app's HTTP/session contract (`spec/parity/expected/django/http.json`)
passes 11/11 against the spike. The official MCP Python SDK client connects,
initializes and lists tools.

Design carried into M1:

```
Rack env → authenticate (→ 401 + WWW-Authenticate: Bearer)
         → env["mcp.auth_info"] = context          # reaches tools as server_context[:auth_info]
         → DELETE: forget session, 200
         → stateful: Mcp-Session-Id rules (400 / 404 / issue on initialize), our own store
         → MCP::Server::Transports::StreamableHTTPTransport.new(server,
             stateless: true, enable_json_response: true, dns_rebinding_protection: false)
         → add Mcp-Session-Id to the response
```

The same structure as `DjangoMCP.handle_django_request`: the SDK always runs
stateless with JSON responses, and the session rules sit in front of it.

## Findings (mcp 1.8.1)

| # | Finding |
|---|---|
| A1 | `mcp` 1.8.1, official (modelcontextprotocol), depends only on `json_schemer`, requires Ruby ≥ 2.7 (A10). |
| A2/A3 | `StreamableHTTPTransport` is a Rack app (`call(env)`). Mounted under `Rack::Builder#map` it ignores the path, so any mount point works. |
| A4/A5 | `stateless: true, enable_json_response: true` answers plain JSON without SDK sessions. Notifications → 202. |
| A6 | Embedded resources pass through untouched. Missing arguments → `isError` result. |
| A7 | Negotiates 2025-03-26, 2025-06-18, 2025-11-25. An unknown version gets the newest handshake version. |
| — | **DNS-rebinding protection is on by default and only accepts loopback `Host` headers.** The endpoint turns it off and leaves host checks to Rails (`config.hosts`). |
| — | **Capabilities**: the SDK default is tools/prompts/resources/logging, while FastMCP sends experimental/prompts/resources/tools. Passing `capabilities:` fixes the keys. Stateless mode strips the `listChanged`/`subscribe: false` flags FastMCP sends, so the parity client compares keys only. |
| — | **Tool errors differ from FastMCP**: an exception → JSON-RPC `-32603` with the message hidden; an unknown tool → JSON-RPC `-32602`. FastMCP returns `isError: true` results with the message ("Error executing tool …", "Unknown tool: …"). `RorMcp::Toolset` / the query tool must rescue and build `isError` responses themselves to match. |
| — | `serverInfo.version` is `"0.1.0"` by default. FastMCP reports the Python `mcp` package version (`"1.30.0"`). Not compared. |
| A9 | Not needed: the official SDK covers everything the port uses, so `fast-mcp` isn't evaluated further. |
| A8 | Partly answered: the Python SDK client accepts the plain JSON responses. Claude Code and MCP Inspector are still to try. |
