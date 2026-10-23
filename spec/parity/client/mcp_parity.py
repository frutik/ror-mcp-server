#!/usr/bin/env python3
"""
Protocol-level MCP parity client (stdlib only).

Talks raw Streamable HTTP / JSON-RPC to an MCP endpoint so the exact status
codes, headers and tool results are visible, then either records them as the
golden set or compares a target against the golden set.

    # record golden output from the Django reference app
    mcp_parity.py record --base-url http://127.0.0.1:8765

    # compare another implementation (the Rails dummy app) against it
    mcp_parity.py check --base-url http://127.0.0.1:3000

Compared: HTTP/session behaviour (status codes, Mcp-Session-Id presence,
WWW-Authenticate), tools/list (names, descriptions, input schemas without
pydantic "title" keys) and every corpus case (content, isError). For cases the
reference answers with an error, only "it is an error" is compared: the port is
allowed to word errors differently. structuredContent is ignored.
"""
import argparse
import difflib
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
PARITY = HERE.parent
CORPUS = PARITY / "pipelines" / "corpus.json"
EXPECTED = PARITY / "expected" / "django"
PROTOCOL_VERSION = "2025-03-26"
SESSION_HDR = "Mcp-Session-Id"


class Endpoint:
    def __init__(self, url, token=None):
        self.url = url
        self.token = token
        self.session = None
        self._next_id = 0

    def request(self, method, payload=None, session=None, auth=True, extra_headers=None):
        headers = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json"}
        if auth and self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if session:
            headers[SESSION_HDR] = session
        headers.update(extra_headers or {})
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(self.url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.status, dict(resp.headers), resp.read().decode()
        except urllib.error.HTTPError as err:
            return err.code, dict(err.headers), err.read().decode()

    def rpc(self, method, params=None, session=None, notification=False, **kw):
        payload = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            payload["params"] = params
        if not notification:
            self._next_id += 1
            payload["id"] = self._next_id
        return self.request("POST", payload, session=session, **kw)

    def initialize(self, **kw):
        return self.rpc("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "ror-mcp-parity", "version": "0"},
        }, **kw)

    def open(self):
        """initialize + notifications/initialized; keeps the session id if the server issues one."""
        status, headers, body = self.initialize()
        if status != 200:
            raise SystemExit(f"initialize on {self.url} failed: {status} {body[:300]}")
        self.session = _header(headers, SESSION_HDR)
        self.rpc("notifications/initialized", session=self.session, notification=True)
        return json.loads(body)["result"]

    def call(self, method, params=None):
        status, _, body = self.rpc(method, params, session=self.session)
        if status != 200:
            return {"_http_status": status, "_body": body[:500]}
        return json.loads(body)


def _header(headers, name):
    for k, v in headers.items():
        if k.lower() == name.lower():
            return v
    return None


def _content_type(headers):
    ct = _header(headers, "Content-Type")
    return ct.split(";")[0].strip() if ct else None


# --- HTTP / session scenarios (PLAN §1A.2) ------------------------------------

def http_scenarios(servers):
    out = {}
    d = Endpoint(servers["default"]["url"])

    def obs(status, headers, body=None, **extra):
        o = {"status": status, "has_session_header": _header(headers, SESSION_HDR) is not None,
             "content_type": _content_type(headers) if status == 200 else None}
        o.update(extra)
        return o

    s, h, b = d.rpc("tools/list")
    out["default/no-session-non-initialize"] = obs(s, h)
    s, h, b = d.rpc("tools/list", session="no-such-session")
    out["default/unknown-session"] = obs(s, h)
    s, h, b = d.initialize()
    session = _header(h, SESSION_HDR)
    res = json.loads(b).get("result", {}) if s == 200 else {}
    out["default/initialize"] = obs(s, h, server_name=res.get("serverInfo", {}).get("name"),
                                    instructions=res.get("instructions"),
                                    protocol_version=res.get("protocolVersion"),
                                    capabilities=sorted(res.get("capabilities", {})))
    s, h, b = d.rpc("notifications/initialized", session=session, notification=True)
    out["default/initialized-notification"] = obs(s, h)
    s, h, b = d.rpc("tools/list", session=session)
    out["default/tools-list-with-session"] = obs(s, h, same_session=_header(h, SESSION_HDR) == session)
    s, h, b = d.request("DELETE", session=session)
    out["default/delete-session"] = obs(s, h, content_type=None)  # Django answers text/html here; not part of the contract
    s, h, b = d.rpc("tools/list", session=session)
    out["default/after-delete"] = obs(s, h)

    a = Endpoint(servers["analytics"]["url"], servers["analytics"]["token"])
    s, h, b = a.initialize(auth=False)
    out["analytics/no-auth"] = obs(s, h, www_authenticate=_header(h, "WWW-Authenticate"))
    s, h, b = a.initialize(extra_headers={"Authorization": "Bearer wrong"}, auth=False)
    out["analytics/bad-token"] = obs(s, h, www_authenticate=_header(h, "WWW-Authenticate"))
    s, h, b = a.initialize()
    res = json.loads(b).get("result", {}) if s == 200 else {}
    out["analytics/initialize"] = obs(s, h, server_name=res.get("serverInfo", {}).get("name"),
                                      instructions=res.get("instructions"))
    s, h, b = a.rpc("tools/list")
    out["analytics/tools-list-no-session"] = obs(s, h)
    return out


# --- tools/list and corpus ----------------------------------------------------

def collect(servers, only=None):
    corpus = json.loads(CORPUS.read_text())["cases"]
    if only:
        corpus = [c for c in corpus if c["id"] in only]
    endpoints = {}
    for name, cfg in servers.items():
        ep = Endpoint(cfg["url"], cfg.get("token"))
        ep.open()
        endpoints[name] = ep

    tools = {name: ep.call("tools/list") for name, ep in endpoints.items()}
    cases = {}
    for case in corpus:
        if "tool" in case:
            params = {"name": case["tool"], "arguments": case["arguments"]}
        else:
            params = {"name": "query_data_collections",
                      "arguments": {"collection": case["collection"], "search_pipeline": case["pipeline"]}}
        cases[case["id"]] = {"case": case, "response": endpoints[case["server"]].call("tools/call", params)}
    return tools, cases


def _dump(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False, sort_keys=True) + "\n")


def record(servers, out_dir, only=None):
    http = http_scenarios(servers)
    tools, cases = collect(servers, only)
    _dump(out_dir / "http.json", http)
    for name, resp in tools.items():
        _dump(out_dir / "tools" / f"{name}.json", resp)
    if not only:
        for stale in (out_dir / "cases").glob("*.json"):
            stale.unlink()
    for cid, data in cases.items():
        _dump(out_dir / "cases" / f"{cid}.json", data)
    print(f"recorded {len(http)} http scenarios, {len(tools)} tool lists, {len(cases)} cases into {out_dir}")


# --- comparison ---------------------------------------------------------------

def _strip_titles(obj):
    if isinstance(obj, dict):
        return {k: _strip_titles(v) for k, v in obj.items() if k != "title"}
    if isinstance(obj, list):
        return [_strip_titles(v) for v in obj]
    return obj


def _diff(a, b):
    a = a if isinstance(a, str) else json.dumps(a, indent=2, sort_keys=True, ensure_ascii=False)
    b = b if isinstance(b, str) else json.dumps(b, indent=2, sort_keys=True, ensure_ascii=False)
    lines = difflib.unified_diff(a.splitlines(), b.splitlines(), "expected", "actual", lineterm="", n=2)
    return "\n".join(list(lines)[:60])


SEARCH_FIELDS_LINE = re.compile(r"^(Full text search is supported on the following fields: )(.*)\.$", re.M)


def _normalize_description(text):
    # django-mcp-server joins a Python set here, so the field order is arbitrary.
    return SEARCH_FIELDS_LINE.sub(lambda m: m.group(1) + ", ".join(sorted(m.group(2).split(", "))) + ".", text or "")


def compare_tools(expected, actual):
    problems = []
    exp = {t["name"]: t for t in expected.get("result", {}).get("tools", [])}
    act = {t["name"]: t for t in actual.get("result", {}).get("tools", [])}
    if set(exp) != set(act):
        problems.append(f"tool names differ: missing {sorted(set(exp) - set(act))}, extra {sorted(set(act) - set(exp))}")
    for name in sorted(set(exp) & set(act)):
        ed, ad = _normalize_description(exp[name].get("description")), _normalize_description(act[name].get("description"))
        if ed != ad:
            problems.append(f"{name}: description differs\n{_diff(ed, ad)}")
        es, as_ = _strip_titles(exp[name].get("inputSchema")), _strip_titles(act[name].get("inputSchema"))
        if es != as_:
            problems.append(f"{name}: inputSchema differs\n{_diff(es, as_)}")
    return problems


def _is_error(resp):
    return "error" in resp or "_http_status" in resp or resp.get("result", {}).get("isError") is True


def compare_case(expected, actual, semantic):
    if _is_error(expected):
        return [] if _is_error(actual) else [f"expected an error, got {json.dumps(actual)[:300]}"]
    if _is_error(actual):
        return [f"unexpected error: {json.dumps(actual, ensure_ascii=False)[:500]}"]
    ec, ac = expected["result"].get("content", []), actual["result"].get("content", [])
    if len(ec) != len(ac):
        return [f"content length {len(ec)} != {len(ac)}\n{_diff(ec, ac)}"]
    problems = []
    for i, (e, a) in enumerate(zip(ec, ac)):
        if e.get("type") != a.get("type"):
            problems.append(f"content[{i}] type {e.get('type')} != {a.get('type')}")
            continue
        if e["type"] == "text":
            problems += _compare_text(f"content[{i}]", e["text"], a["text"], semantic)
        elif e["type"] == "resource":
            er, ar = e["resource"], a["resource"]
            for k in ("uri", "mimeType"):
                if er.get(k) != ar.get(k):
                    problems.append(f"content[{i}].resource.{k} {er.get(k)!r} != {ar.get(k)!r}")
            problems += _compare_text(f"content[{i}].resource", er.get("text", er.get("blob")),
                                      ar.get("text", ar.get("blob")), semantic)
        elif e != a:
            problems.append(f"content[{i}] differs\n{_diff(e, a)}")
    return problems


def _compare_text(where, e, a, semantic):
    if e == a:
        return []
    try:
        same_json = json.loads(e) == json.loads(a)
    except (TypeError, ValueError):
        same_json = False
    if same_json:
        return [] if semantic else [f"{where}: same JSON, different bytes\n{_diff(e, a)}"]
    return [f"{where} differs\n{_diff(e, a)}"]


def check(servers, exp_dir, semantic, only=None, http_only=False):
    failures = 0

    def report(label, problems):
        nonlocal failures
        if problems:
            failures += 1
            print(f"FAIL {label}")
            for p in problems:
                print("     " + p.replace("\n", "\n     "))
        else:
            print(f"ok   {label}")

    if not only:
        exp_http = json.loads((exp_dir / "http.json").read_text())
        act_http = http_scenarios(servers)
        for key, e in exp_http.items():
            a = act_http.get(key, {})
            report(f"http {key}", [f"{k}: expected {e[k]!r}, got {a.get(k)!r}" for k in e if a.get(k) != e[k]])

    if http_only:
        print(f"\n{len(exp_http) - failures}/{len(exp_http)} passed")
        return 1 if failures else 0

    tools, cases = collect(servers, only)
    if not only:
        for name, resp in tools.items():
            report(f"tools/list {name}", compare_tools(json.loads((exp_dir / "tools" / f"{name}.json").read_text()), resp))
    for cid, data in cases.items():
        exp_file = exp_dir / "cases" / f"{cid}.json"
        if not exp_file.exists():
            report(f"case {cid}", ["no expected output recorded"])
            continue
        report(f"case {cid}", compare_case(json.loads(exp_file.read_text())["response"], data["response"], semantic))

    total = len(cases) + (0 if only else len(tools) + len(exp_http))
    print(f"\n{total - failures}/{total} passed")
    return 1 if failures else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["record", "check"])
    ap.add_argument("--base-url", default="http://127.0.0.1:8765")
    ap.add_argument("--default-path", default="/mcp")
    ap.add_argument("--analytics-path", default="/mcp/analytics")
    ap.add_argument("--analytics-token", default="parity-secret")
    ap.add_argument("--expected", type=Path, default=EXPECTED, help="golden directory (record writes here)")
    ap.add_argument("--semantic", action="store_true", help="accept JSON text that differs only in bytes")
    ap.add_argument("--only", help="comma-separated case ids")
    ap.add_argument("--http-only", action="store_true", help="check only the HTTP/session scenarios (milestone M1)")
    args = ap.parse_args()

    base = args.base_url.rstrip("/")
    servers = {
        "default": {"url": base + args.default_path},
        "analytics": {"url": base + args.analytics_path, "token": args.analytics_token},
    }
    only = set(args.only.split(",")) if args.only else None
    if args.mode == "record":
        record(servers, args.expected, only)
        return 0
    return check(servers, args.expected, args.semantic, only, args.http_only)


if __name__ == "__main__":
    sys.exit(main())
