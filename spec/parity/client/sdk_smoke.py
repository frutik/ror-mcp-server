#!/usr/bin/env python3
"""
Smoke test with the official MCP Python SDK client (what real MCP clients do):
connect over Streamable HTTP, initialize, list tools, call a query and a tool
on both servers. Exits non-zero on the first failure.

    sdk_smoke.py --base-url http://127.0.0.1:8765
"""
import argparse
import asyncio
import json
import sys

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


async def exercise(url, headers, query_args, tool_name, expected_tools):
    async with streamablehttp_client(url, headers=headers) as (read, write, _):
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            tools = {t.name for t in (await session.list_tools()).tools}
            missing = expected_tools - tools
            assert not missing, f"{url}: missing tools {missing} (got {sorted(tools)})"
            res = await session.call_tool("query_data_collections", query_args)
            assert not res.isError, f"{url}: query failed: {res.content}"
            tool_res = await session.call_tool(tool_name, {})
            assert not tool_res.isError, f"{url}: {tool_name} failed: {tool_res.content}"
            first = res.content[0]
            preview = first.text if first.type == "text" else json.dumps(first.model_dump(mode="json"))
            print(f"ok   {url}: server={init.serverInfo.name} tools={len(tools)} query→ {preview[:80]}")


async def main(base, token):
    await exercise(
        base + "/mcp", None,
        {"collection": "order", "search_pipeline": [{"$sort": {"id": 1}}, {"$limit": 2}, {"$project": {"number": 1}}]},
        "get_server_instructions",
        {"get_server_instructions", "query_data_collections", "add", "customer_order_count", "latest_order", "explode"},
    )
    await exercise(
        base + "/mcp/analytics", {"Authorization": f"Bearer {token}"},
        {"collection": "vipcustomer", "search_pipeline": [{"$limit": 1}, {"$project": {"name": 1}}]},
        "line_item_count",
        {"get_server_instructions", "query_data_collections", "revenue_by_status", "line_item_count"},
    )


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default="http://127.0.0.1:8765")
    ap.add_argument("--analytics-token", default="parity-secret")
    args = ap.parse_args()
    try:
        asyncio.run(main(args.base_url.rstrip("/"), args.analytics_token))
    except AssertionError as err:
        print(f"FAIL {err}")
        sys.exit(1)
