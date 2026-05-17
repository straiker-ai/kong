#!/usr/bin/env python3
"""Bootstrap a Konnect control plane for the AI Proxy Advanced + Straiker test.

Creates:
  - service "openai-via-advanced" (placeholder upstream; ai-proxy-advanced rewrites)
  - route "/chat-agentic" on that service
  - ai-proxy-advanced plugin on the route (OpenAI provider, streaming on)
  - straiker plugin on the route (agentic=true, ai_proxy_advanced_compat=true)
  - also a second route "/chat-baseline" with straiker compat=false (for before/after)

Idempotent: deletes any prior copies of these named entities before creating.
"""
import json, os, sys, urllib.request, urllib.error

CP = os.environ["KONNECT_ADMIN_API"]
PAT = os.environ["KONNECT_PAT"]
OPENAI_KEY = os.environ["OPENAI_API_KEY"]
STRAIKER_KEY = os.environ["STRAIKER_API_KEY"]

def req(method, path, body=None):
    url = f"{CP}{path}"
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, method=method, data=data, headers={
        "Authorization": f"Bearer {PAT}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(r) as resp:
            txt = resp.read().decode()
            return resp.status, (json.loads(txt) if txt else {})
    except urllib.error.HTTPError as e:
        body_txt = e.read().decode()
        try: body_json = json.loads(body_txt)
        except Exception: body_json = {"raw": body_txt}
        return e.code, body_json

def find_by_name(kind, name):
    code, data = req("GET", f"/core-entities/{kind}?name={name}")
    if code != 200: return None
    for item in data.get("data", []):
        if item.get("name") == name:
            return item
    return None

def teardown_service(svc_id):
    """Delete plugins -> routes -> service in dependency order."""
    c, d = req("GET", f"/core-entities/services/{svc_id}/routes")
    routes = (d or {}).get("data", []) if c == 200 else []
    for r in routes:
        # plugins on the route
        cp, dp = req("GET", f"/core-entities/routes/{r['id']}/plugins")
        for p in (dp or {}).get("data", []) if cp == 200 else []:
            req("DELETE", f"/core-entities/plugins/{p['id']}")
        # service-level plugins reference this route? handle separately if needed.
        req("DELETE", f"/core-entities/routes/{r['id']}")
        print(f"  deleted route {r.get('name')} ({r['id']})")
    # plugins directly on the service
    cp, dp = req("GET", f"/core-entities/services/{svc_id}/plugins")
    for p in (dp or {}).get("data", []) if cp == 200 else []:
        req("DELETE", f"/core-entities/plugins/{p['id']}")
    rc, _ = req("DELETE", f"/core-entities/services/{svc_id}")
    print(f"  deleted service ({svc_id}) -> HTTP {rc}")

def upsert_service(name, body):
    existing = find_by_name("services", name)
    if existing:
        teardown_service(existing["id"])
    body["name"] = name
    c, d = req("POST", "/core-entities/services", body)
    print(f"  created services/{name} -> HTTP {c}")
    if c >= 300:
        print(f"    error body: {json.dumps(d)[:500]}")
        sys.exit(1)
    return d.get("item") or d

def upsert_route(name, body):
    existing = find_by_name("routes", name)
    if existing:
        # cascade: delete plugins on this route first
        cp, dp = req("GET", f"/core-entities/routes/{existing['id']}/plugins")
        for p in (dp or {}).get("data", []) if cp == 200 else []:
            req("DELETE", f"/core-entities/plugins/{p['id']}")
        c, _ = req("DELETE", f"/core-entities/routes/{existing['id']}")
        print(f"  deleted prior route {name} ({existing['id']}) -> HTTP {c}")
    body["name"] = name
    c, d = req("POST", "/core-entities/routes", body)
    print(f"  created routes/{name} -> HTTP {c}")
    if c >= 300:
        print(f"    error body: {json.dumps(d)[:500]}")
        sys.exit(1)
    return d.get("item") or d

def upsert(kind, name, body):
    return upsert_service(name, body) if kind == "services" else upsert_route(name, body)

def delete_plugins_on_route(route_id):
    c, d = req("GET", f"/core-entities/routes/{route_id}/plugins")
    if c != 200: return
    for p in d.get("data", []):
        req("DELETE", f"/core-entities/plugins/{p['id']}")
        print(f"  deleted stale plugin {p.get('name')} ({p['id']}) on route {route_id}")

def create_plugin(route_id, name, config):
    body = {"name": name, "route": {"id": route_id}, "config": config}
    c, d = req("POST", "/core-entities/plugins", body)
    print(f"  plugin {name} on route {route_id} -> HTTP {c}")
    if c >= 300:
        print(f"    error body: {json.dumps(d)[:600]}")
        sys.exit(1)
    return d.get("item") or d

# ---- 1. service ----
print("== service ==")
svc = upsert("services", "openai-via-advanced", {
    # ai-proxy-advanced overrides the upstream URL; this is a placeholder
    "url": "http://placeholder.invalid",
    "retries": 0,
})

# ---- 2. routes ----
print("== routes ==")
route_agentic = upsert("routes", "chat-agentic", {
    "service": {"id": svc["id"]},
    # ^= is "starts with" — lets OpenAI client POST /chat-agentic/chat/completions
    "expression": '(http.path ^= "/chat-agentic") && (http.method == "POST")',
    "priority": 1,
    "strip_path": True,
})

route_baseline = upsert("routes", "chat-baseline", {
    "service": {"id": svc["id"]},
    "expression": '(http.path ^= "/chat-baseline") && (http.method == "POST")',
    "priority": 1,
    "strip_path": True,
})

# ---- 3. plugins ----
print("== plugins on chat-agentic ==")
delete_plugins_on_route(route_agentic["id"])

create_plugin(route_agentic["id"], "ai-proxy-advanced", {
    "targets": [{
        "route_type": "llm/v1/chat",
        "model": {
            "provider": "openai",
            "name": "gpt-4o-mini",
            "options": {"max_tokens": 512},
        },
        "auth": {
            "header_name": "Authorization",
            "header_value": f"Bearer {OPENAI_KEY}",
        },
    }],
})

create_plugin(route_agentic["id"], "straiker", {
    "api_key": STRAIKER_KEY,
    "detect_url": "https://api.prod.straiker.ai/api/v1/detect",
    "source": "kong-ai-proxy-advanced",
    "destination": "api.openai.com",
    # post_call so agent loops complete; pre-call blocking is exercised separately on the
    # blocking-demo route below. Tenant has LLM Evasion in block mode, which over-fires on
    # nearly all agent traffic and prevents real multi-step flows from completing.
    "mode": "post_call",
    "agentic": True,
    "threshold": 0.5,
    "timeout": 5000,
    "fail_open": False,
    "ai_proxy_advanced_compat": True,
})

print("== plugins on chat-baseline ==")
delete_plugins_on_route(route_baseline["id"])

create_plugin(route_baseline["id"], "ai-proxy-advanced", {
    "targets": [{
        "route_type": "llm/v1/chat",
        "model": {
            "provider": "openai",
            "name": "gpt-4o-mini",
            "options": {"max_tokens": 512},
        },
        "auth": {
            "header_name": "Authorization",
            "header_value": f"Bearer {OPENAI_KEY}",
        },
    }],
})

create_plugin(route_baseline["id"], "straiker", {
    "api_key": STRAIKER_KEY,
    "detect_url": "https://api.prod.straiker.ai/api/v1/detect",
    "source": "kong-ai-proxy-advanced-baseline",
    "destination": "api.openai.com",
    "mode": "both",
    "agentic": False,
    "threshold": 0.5,
    "timeout": 5000,
    "fail_open": False,
    "ai_proxy_advanced_compat": False,  # legacy v0.3.x path — should show N/A on streaming
})

print()
print("done.")
print("  POST http://localhost:8000/chat-agentic   (v0.4.0 SSE-aware, agentic)")
print("  POST http://localhost:8000/chat-baseline  (legacy path, expected to N/A on streaming)")
