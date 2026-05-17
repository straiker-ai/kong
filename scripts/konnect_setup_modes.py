#!/usr/bin/env python3
"""Add 5 mode-coverage routes to the Konnect control plane, alongside the
existing chat-agentic and chat-baseline routes.

Routes added:
  /test-pre-agentic       mode=pre_call    agentic=true   compat=true
  /test-both-agentic      mode=both        agentic=true   compat=true
  /test-pre-chatbot       mode=pre_call    agentic=false  compat=true
  /test-post-chatbot      mode=post_call   agentic=false  compat=true
  /test-both-chatbot      mode=both        agentic=false  compat=true

Each route attaches ai-proxy-advanced (OpenAI gpt-4o-mini) + straiker plugin
configured per the matrix above. `source` per route is "kong-mode-<route>".
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
        "Authorization": f"Bearer {PAT}", "Content-Type": "application/json"})
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
        if item.get("name") == name: return item
    return None

def teardown_route(route):
    cp, dp = req("GET", f"/core-entities/routes/{route['id']}/plugins")
    for p in (dp or {}).get("data", []) if cp == 200 else []:
        req("DELETE", f"/core-entities/plugins/{p['id']}")
    req("DELETE", f"/core-entities/routes/{route['id']}")

def upsert_route(name, body, svc_id):
    existing = find_by_name("routes", name)
    if existing:
        teardown_route(existing)
        print(f"  removed prior route {name}")
    body["name"] = name
    body["service"] = {"id": svc_id}
    c, d = req("POST", "/core-entities/routes", body)
    print(f"  created routes/{name} -> HTTP {c}")
    if c >= 300:
        print(f"    error: {json.dumps(d)[:400]}")
        sys.exit(1)
    return d.get("item") or d

def create_plugin(route_id, name, config):
    body = {"name": name, "route": {"id": route_id}, "config": config}
    c, d = req("POST", "/core-entities/plugins", body)
    print(f"    {name} -> HTTP {c}")
    if c >= 300:
        print(f"      error: {json.dumps(d)[:600]}")
        sys.exit(1)

# locate existing openai-via-advanced service
svc = find_by_name("services", "openai-via-advanced")
if not svc:
    print("ERROR: service 'openai-via-advanced' not found. Run konnect_setup.py first.")
    sys.exit(1)
svc_id = svc["id"]
print(f"using service openai-via-advanced ({svc_id})")

AI_PROXY_CONFIG = {
    "targets": [{
        "route_type": "llm/v1/chat",
        "model": {"provider": "openai", "name": "gpt-4o-mini", "options": {"max_tokens": 512}},
        "auth": {"header_name": "Authorization", "header_value": f"Bearer {OPENAI_KEY}"},
    }],
}

def straiker_config(mode, agentic, source, threshold=0.5):
    return {
        "api_key": STRAIKER_KEY,
        "detect_url": "https://api.prod.straiker.ai/api/v1/detect",
        "source": source,
        "destination": "api.openai.com",
        "mode": mode,
        "agentic": agentic,
        "threshold": threshold,
        "timeout": 5000,
        "fail_open": False,
        "ai_proxy_advanced_compat": True,
    }

MATRIX = [
    # path,                 mode,         agentic, source
    ("test-pre-agentic",    "pre_call",   True,    "kong-mode-pre-agentic"),
    ("test-both-agentic",   "both",       True,    "kong-mode-both-agentic"),
    ("test-pre-chatbot",    "pre_call",   False,   "kong-mode-pre-chatbot"),
    ("test-post-chatbot",   "post_call",  False,   "kong-mode-post-chatbot"),
    ("test-both-chatbot",   "both",       False,   "kong-mode-both-chatbot"),
]

print("\n=== mode-coverage matrix ===")
for path, mode, agentic, source in MATRIX:
    route_name = path  # alias
    expr = f'(http.path ^= "/{path}") && (http.method == "POST")'
    print(f"\n[{route_name}] mode={mode} agentic={agentic} source={source}")
    r = upsert_route(route_name, {
        "expression": expr, "priority": 1, "strip_path": True,
    }, svc_id)
    create_plugin(r["id"], "ai-proxy-advanced", AI_PROXY_CONFIG)
    # threshold default 0.5 means LLM Evasion FPs WILL block some benign
    # prompts on pre_call routes; that's expected behavior and what we want
    # to demonstrate.
    create_plugin(r["id"], "straiker", straiker_config(mode, agentic, source))

print("\ndone. routes created:")
for path, *_ in MATRIX:
    print(f"  POST http://localhost:8000/{path}")
