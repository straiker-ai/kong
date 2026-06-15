# Straiker Kong Plugin — Design, Flow Matrix & Operations

Kong Gateway plugins that call Straiker `POST /api/v1/detect` (or
`/api/v1/detect?agentic`) on every AI request flowing through Kong. Intended as
the production protection point in front of OpenAI, Anthropic, Bedrock, etc.

The repo ships **two builds of the same capability**, one per deployment topology:

| Plugin | For | How post-call works |
|---|---|---|
| **`straiker`** | Self-hosted Kong (OSS/Enterprise) and Konnect **hybrid** (self-managed data plane) | Timer-based, fire-and-forget — streaming-friendly, full feature set |
| **`straiker-saas`** | Konnect **full-SaaS Dedicated Cloud Gateways** | Buffered `response` phase (no timers — the Dedicated Cloud sandbox forbids them); synchronous response eval **and** response blocking. Buffers the answer, so token streaming is unsupported on this build |

**Which one do I use?** See **§12 Deployment patterns & support matrix**. The
`straiker-saas` build is documented in **§13**. Sections 1–11 describe the
`straiker` plugin; almost everything (config, the flow matrix, app-source
resolution) applies to both — §13 covers only the differences.

This document is the source of truth on how the plugins behave. Read sections
1–3 to understand the architecture; section 4 is the **flow matrix** that
explains exactly what shows up in the Straiker Console for every combination
of route type (chatbot vs agentic), control mode (detect vs block), and
request outcome (allowed vs blocked).

---

## 1. Plugin install vs. plugin attachment

Kong separates **what the plugin is** from **where it runs**:

| Concept | Where it lives | Set once, or per route? |
|---|---|---|
| Plugin install (the code) | LuaRocks artifact installed into Kong's standard plugin path | Once per Kong instance |
| Plugin **attachment** (the config) | `kong.yml` services/routes block, or Admin API | Per route — each attachment gets its own `config: { ... }` |

Recommended install for **self-hosted Kong** and **Konnect hybrid (self-managed
data plane)** — one command installs both plugins; enable whichever the topology
needs via `KONG_PLUGINS`:

```bash
luarocks install https://github.com/PhimmStraiker/kong-plugin-straiker/releases/download/v0.8.0/kong-plugin-straiker-0.8.0-1.all.rock
export KONG_PLUGINS=bundled,straiker          # self-hosted / hybrid (timer build)
# export KONG_PLUGINS=bundled,straiker-saas   # response-phase build (also fine here)
kong reload
```

> **Konnect full-SaaS (Dedicated Cloud Gateways)** doesn't use this rock — you
> can't `luarocks install` on a Kong-managed data plane. Instead upload the two
> `straiker-saas` files via the Konnect UI/API. See **§13** (topologies) and
> **§14** (the `straiker-saas` build + upload steps).

The `agentic` flag, the API key, the threshold, the mode — all of it lives on
the attachment. One Kong install can attach the plugin to a chatbot route with
`agentic: false` and to an agent route with `agentic: true` simultaneously.

---

## 2. Two route shapes

| Shape | `agentic` config | Endpoint | When to use |
|---|---|---|---|
| **Chatbot** | `false` | `POST /api/v1/detect` | Single-shot completions: chatbots, RAG Q&A, copilots whose retrieval happens inside the customer's app before the OpenAI call |
| **Agentic** | `true` | `POST /api/v1/detect?agentic` | OpenAI tool / function calling, LangChain/LangGraph/OpenAI Agents SDK, anything that loops Kong → OpenAI multiple times for one user prompt |

You can run both side-by-side in one Kong, attached to different routes.

---

## 3. How blocking actually works

**Blocking = the plugin returns HTTP 403 to the client before forwarding upstream.**

Sequence:

1. Client → Kong → plugin's `access` phase.
2. Plugin sends the request payload to Straiker (`/api/v1/detect` for chatbot routes, `/api/v1/detect?agentic` for agentic routes).
3. Straiker runs all configured controls, returns response with `score` field.
4. **If `score > config.threshold` (default 0.5):** plugin calls `kong.response.exit(403, ...)` — Kong returns 403 to the client, OpenAI is **never** called.
5. **If `score ≤ threshold`:** plugin lets the request flow through to OpenAI. After the OpenAI response comes back, the plugin asynchronously fires a *second* detect call (post-call observability) so the response content is also analysed.

Two important notes:

- **`detect` vs `block` mode is set in the Straiker Console**, per control, on the application. `detect` triggers don't change the `score` enough to cross the threshold; `block` triggers do. The plugin doesn't know which mode any individual control is in — it only sees the aggregate `score` Straiker returned.
- **Pre-call hook runs only on the first iteration of an agent loop** (when `messages[-1].role == "user"`). On continuation iterations (last message is a tool result or intermediate assistant reasoning), pre-call is skipped to avoid duplicate Console turns from one logical user interaction.

---

## 4. Flow Matrix — what shows in Console for every combination

**Notation:** "1 turn = 1 pre + 0 post" means the Console will show **one** row in Activity, created from the pre-call detect API call. "2 turns = 1 pre + 1 post" means **two** rows for one user interaction (the input pre-call and the response post-call).

### 4.1 Chatbot route (`agentic: false`)

| Scenario | Pre-call fires? | Post-call fires? | HTTP code | Console turns | What you see |
|---|---|---|---|---|---|
| Benign prompt, all controls in detect | ✅ score=0 | ✅ score=0 | 200 | **2** (1 pre + 1 post) | Pre-call: prompt, no badges. Post-call: prompt + assistant response, no badges. |
| Benign prompt, controls in block | ✅ score=0 | ✅ score=0 | 200 | **2** (1 pre + 1 post) | Same as above. Block mode only fires on flagged content; benign content isn't blocked. |
| Adversarial prompt, control in **detect** mode | ✅ score=1 | ✅ score=1 | 200 | **2** (1 pre + 1 post) | Pre-call: prompt with red violation badge (e.g. "LLM Evasion"). Post-call: prompt + response with same badge. Model still answered. |
| Adversarial prompt, control in **block** mode | ✅ score=1, blocks | ❌ skipped (request never reached upstream) | **403** | **1** (1 pre, 0 post) | Pre-call turn with prompt + empty response box. Body of 403 returned to client carries `turn_id`, `score`, message. |

### 4.2 Agentic route (`agentic: true`) — single-iteration call (no tools)

This is the case where the customer's "agent" doesn't actually use tool calling — it's effectively the same wire shape as a chatbot, just routed through `/detect?agentic`.

| Scenario | Pre-call fires? | Post-call fires? | HTTP code | Console turns |
|---|---|---|---|---|
| Benign prompt, controls in detect | ✅ score=0 | ✅ score=0 | 200 | **2** (1 pre + 1 post) |
| Adversarial prompt, control in detect | ✅ score=1 | ✅ score=1 | 200 | **2** (1 pre + 1 post) |
| Adversarial prompt, control in block | ✅ score=1, blocks | ❌ skipped | **403** | **1** |

### 4.3 Agentic route (`agentic: true`) — multi-iteration agent loop

The agent makes N sequential OpenAI calls to fulfil one user prompt: user message → assistant tool_calls → tool result → assistant tool_calls → tool result → final assistant content. Each OpenAI call is a separate Kong request.

The plugin dedupes:

- **Pre-call** fires only on iteration 1 (when `messages[-1].role == "user"`). Iterations 2..N are continuations (last message is `tool` or intermediate `assistant`), pre-call is skipped on those.
- **Post-call** fires only on the iteration where the response has no `tool_calls` — i.e. the final-answer iteration. Intermediate tool-call-only responses skip post-call.

Per logical user interaction, regardless of how many tool iterations the agent runs:

| Scenario | Total Console turns | What's in them |
|---|---|---|
| Benign prompt, controls in detect | **2** | Pre-call (with full `messages[]` at iteration 1) + post-call (with full `messages[]` at final iteration, including all `tool_calls` and tool results inline as Agentic Steps) |
| Adversarial prompt, control in detect | **2** | Same shape, both turns flagged with the violating control |
| Adversarial prompt, control in **block** mode | **1** | Pre-call only — request never reached the agent loop. HTTP 403 to client. |

### 4.4 Multi-prompt session (same user, multiple consecutive prompts)

A user has a long conversation: prompt 1 → response 1 → prompt 2 → response 2 → prompt 3 → response 3. Same `x-session-id` on every Kong call.

| Per prompt | Total turns for the session |
|---|---|
| Each prompt produces 2 turns (pre + post) if allowed, 1 turn if blocked | 2 × (allowed prompts) + 1 × (blocked prompts) |

Filtering Activity by `session_id` shows the whole timeline.

### 4.5 Multi-agent / multi-model (one user prompt → researcher agent + writer agent)

One user prompt fans out across two specialised agents on two different models. Same `session_id`, distinct `agent_role` on each call.

| Per agent | Total turns for the user interaction |
|---|---|
| Each agent produces 1 pre + 1 post if allowed, or 1 pre if blocked | 4 turns total when both agents allowed (2 per agent), 1 turn if the first agent's input was blocked |

The `metadata.trace_id` and `metadata.agent_role` fields stitch the trace in the Console — filter Activity by `trace_id` to see all hops in time order.

---

## 5. What gets sent to Straiker on every call

### Chatbot (`/api/v1/detect`) payload

```json
{
  "prompt":       "<last user message>",
  "app_response": "<assistant content (post-call only; 'N/A' on pre-call)>",
  "rag_content":  "N/A",
  "session_id":   "<x-session-id header or fallback>",
  "user_name":    "<resolved identity>",
  "user_role":    "<x-user-role header or 'public'>",
  "metadata": {
    "session_id": "...", "user_name": "...", "user_role": "...",
    "remote_ip":  "...", "app_name":  "<plugin source>",
    "source":     "kong-plugin",
    "trace_id":   "<x-trace-id>",  "agent_role": "<x-agent-role>"
  },
  "network":      { "IP": "...", "User-Agent": "...", "Content-Type": "..." },
  "annotations":  { "source": "kong-plugin", "model": "...", "hook": "<pre|post>_call",
                    "trace_id": "...", "agent_role": "..." }
}
```

### Agentic (`/api/v1/detect?agentic`) payload

Same envelope, plus the full conversation `messages[]`:

```json
{
  "source":       "<must match an existing agentic Straiker app>",
  "destination":  "api.openai.com",
  "messages": [
    {"role": "system",    "content": "..."},
    {"role": "user",      "content": "..."},
    {"role": "assistant", "tool_calls": [
      {"id": "call_abc", "name": "lookup_order", "input": {"order_id": "ORD-4421"}}
    ]},
    {"role": "tool", "tool_call_id": "call_abc", "tool_name": "lookup_order",
                     "content": "{\"customer\":\"...\"}"},
    {"role": "assistant", "content": "Your order shipped on Tuesday."}
  ],
  "session_id":   "...",
  "user_name":    "...",
  "metadata":     { /* same envelope as chatbot */ },
  "annotations":  { /* same as chatbot */ }
}
```

OpenAI's native tool_calls format (`{id, type, function:{name, arguments:"<json>"}}`) is **reshaped on the wire** to Straiker's flat format (`{id, name, input:<object>}`). Without that reshape the Console can't render tool names or arguments.

---

## 6. Deployment recommendations

- **Start in detect mode.** Bring controls up in `detect` first and review the
  Activity feed before switching any control to `block`. Block mode returns
  HTTP 403 to the end user, so validate the false-positive rate on real traffic
  per control before enabling it — prompt-injection controls in particular can
  over-fire on benign questions.
- **Set a stable `x-session-id`.** The plugin derives the session from the
  `x-session-id` header, falling back to the per-request Kong request id. Have
  the calling app set a stable `x-session-id` for one logical conversation so
  multi-turn and multi-iteration interactions group correctly in the Console.

## 7. Identity, session, and trace correlation (operator reference)

Headers the plugin reads from the upstream client request and forwards to Straiker:

| Header | Straiker field | Purpose |
|---|---|---|
| `x-user-name` | `metadata.user_name` (and top-level) | End-user identity. Falls back to Kong consumer username/custom_id, then OpenAI `user` body field, then `"kong"`. |
| `x-user-role` | `metadata.user_role` | Role label for RBAC-aware controls. Defaults to `"public"`. |
| `x-session-id` | `metadata.session_id` | Stable session identifier. Same value on every Kong → OpenAI hop in one logical conversation. |
| `x-trace-id` | `metadata.trace_id` (and `annotations.trace_id`) | Optional distributed-trace identifier. Useful when the agent runtime already issues W3C Trace Context. |
| `x-agent-role` | `metadata.agent_role` (and `annotations.agent_role`) | Free-form label (`researcher`, `writer`, etc.) so multi-agent flows can be distinguished. |

---

## 8. Operational gotchas

- **Response decompression.** OpenAI returns `Content-Encoding: gzip` (or `br`) by default. Plugin sets `Accept-Encoding: identity` upstream so `body_filter` sees parseable JSON.
- **Cosockets in `body_filter`.** Kong forbids cosocket I/O in body_filter. Plugin defers post-call detection to `ngx.timer.at(0, …)` from the log phase.
- **`Content-Length` rewrite.** Plugin clears `ngx.header.content_length` in `header_filter` so the buffered body re-emits correctly.
- **Payload logging.** Outgoing Straiker payload is logged at `DEBUG` only. Production deployments don't write user prompts to nginx access logs by default.
- **DB-less Kong reload.** Use `curl -X POST http://localhost:8001/config -F config=@kong.yml`; `PATCH` is not supported.
- **`api_key` storage.** Declared `encrypted = true` and `referenceable = true`, so Kong stores it encrypted at rest and resolves `{vault://...}` references for production deployments.

---

## 9. Configuration reference

| Field | Default | Description |
|---|---|---|
| `api_key` | (required) | Straiker Defend AI API key. Encrypted at rest. |
| `detect_url` | `https://api.prod.straiker.ai/api/v1/detect` | Straiker endpoint. Override for regional deployments. |
| `mode` | `both` | `pre_call`, `post_call`, or `both`. Applies to chatbot routes only. Agentic routes always run pre+post per the §4.3 dedupe rules. |
| `agentic` | `false` | When `true`, calls `/detect?agentic`, forwards full `messages[]` (tool_calls reshaped). Pre-call fires only on first iteration of agent loop; post-call only on final-answer iteration. |
| `source` | `kong-plugin` | Agentic application name. Must match an existing agentic Straiker app. |
| `destination` | `api.openai.com` | Upstream provider hostname, recorded in agentic detection metadata. |
| `threshold` | `0.5` | Minimum score to block. Higher = more permissive. |
| `timeout` | `5000` | Straiker call timeout in milliseconds. |
| `fail_open` | `false` | When `true`, allow traffic through if Straiker is unreachable. |
| `ai_proxy_advanced_compat` | `false` | Enable when the route also has `ai-proxy` / `ai-proxy-advanced` attached. Turns on the SSE-aware response accumulator so streamed `chat.completion.chunk` events are reassembled into a single `app_response` before posting to `/detect`. See §11. |
| `app_id_header` | `"off"` | Name of a request header that already carries the app identifier (e.g. `x-app-id`). **Tier 1** of app source resolution — use when an edge/request-transformer or the calling app sets the header directly. Set to `"off"` to disable. See §10. |
| `jwt_app_claim` | `"off"` | JWT claim to use as the per-request app source. **Tiers 2–3** of app source resolution. **This is the Microsoft Entra / Azure AD path** — pair it with Kong's `openid-connect` (or `jwt`) plugin. Values: `"auto"` (tries `app_displayname` → `azp` → `appid`; recommended), `"appid"` (Entra v1 app-only tokens), `"azp"` (Entra v2 tokens), `"off"` (disabled). See §10. |

---

## 10. Automatic App Source Resolution (v0.6.0+)

### 10.1 The problem: one route, one key, many apps

In an enterprise model gateway, a single Kong route exposes an OpenAI-compatible
endpoint to many internal teams. Each team's app authenticates with the company
IdP (Microsoft Entra / Azure AD, Okta, …) and forwards its token as
`Authorization: Bearer <jwt>` on every call. Kong validates the token centrally.

From the gateway's perspective every request looks identical — same route, same
Straiker API key — so without extra configuration all traffic lands in the
Console under one app (`source = "kong-plugin"`). That makes per-app dashboards,
policy, and attribution impossible.

The `source` field in the `/detect?agentic` payload maps to a Straiker
application, and a new value auto-creates a new app profile. v0.6.0 derives
`source` per request from the **verified caller identity**, so every app team
gets its own profile automatically — one Kong route, one key, no per-app setup.

### 10.2 Three ways to resolve the app identity

`resolve_app_source()` tries three tiers in order; the configured `source` is
the fallback when none resolve.

| Tier | Config | Where the identity comes from | Verified by Kong? |
|---|---|---|---|
| **1** | `app_id_header` | A request header (e.g. `x-app-id`) set by an edge component, a `request-transformer`, or the app itself | Depends on who set it |
| **2** | `jwt_app_claim` | The validated JWT in `kong.ctx.shared.authenticated_jwt_token`, left there by `openid-connect` or the `jwt` plugin | **Yes** — signature-checked against the IdP |
| **3** | `jwt_app_claim` | The raw `Authorization: Bearer` token, decoded directly | No |

**For Microsoft Entra / Azure AD, use Tier 2.** It is the only path that is both
automatic (the app sends only its normal token) *and* signature-verified (Kong
rejects forged tokens before the plugin runs). The rest of this section focuses
on it.

### 10.3 The verified Entra production pattern (Tier 2)

```
  App (Entra JWT)                 Kong Gateway                          Upstream
  ───────────────   ┌─────────────────────────────────────────────┐
  Authorization:    │ openid-connect  (validate vs tenant JWKS)    │
  Bearer eyJ…  ───► │   • rejects invalid/expired → 401            │
                    │   • stores the VERIFIED token in             │
                    │     kong.ctx.shared.authenticated_jwt_token  │
                    │ ai-proxy-advanced                            │
                    │   • replaces Authorization with the provider │ ──► OpenAI/
                    │     key (OpenAI / Bedrock / …)               │     Bedrock/…
                    │ straiker  (PRIORITY 760)                     │
                    │   • reads the verified token from SHARED     │
                    │     CONTEXT — not the header                 │
                    │   • extracts azp / appid → source            │
                    └─────────────────────────────────────────────┘
                                       │ source = <calling app client id>
                                       ▼
                           Straiker: per-app profile auto-created
```

Two facts make this work, both confirmed against a live Entra tenant:

1. `openid-connect` leaves the **validated** token in
   `kong.ctx.shared.authenticated_jwt_token`. The plugin reads it there, so it
   never has to parse or trust a header.
2. That shared value is **request context, not a header**, so it survives
   `ai-proxy-advanced` replacing the `Authorization` header with the upstream
   provider key. (Tier 3 — decoding `Authorization` directly — does **not** work
   on `ai-proxy-advanced` routes for exactly this reason: the original token is
   gone by the time the plugin's `access` phase runs.)

**Kong `openid-connect` config (bearer validation):**

```yaml
plugins:
  - name: openid-connect
    config:
      issuer: https://login.microsoftonline.com/<tenant-id>/v2.0
      auth_methods: ["bearer"]
      # An app registration in your tenant; used to satisfy audience validation
      # (aud == client_id for v2 tokens).
      client_id: ["<gateway-app-client-id>"]
      client_secret: ["<secret>"]
```

**Straiker plugin config:**

```yaml
  - name: straiker
    config:
      api_key: ${STRAIKER_API_KEY}
      agentic: true
      jwt_app_claim: "auto"        # azp (v2) or appid (v1) — auto handles both
      ai_proxy_advanced_compat: true
      source: "model-gateway"      # fallback when no validated token is present
```

> No `upstream_headers` claim-to-header mapping is required. The
> `openid-connect` claim-injection feature maps **id_token / userinfo** claims,
> not **bearer access-token** claims, so it does *not* populate an `x-app-id`
> header for app-only Entra tokens. Tier 2 reads the access token from shared
> context instead — simpler, and no extra config.

### 10.4 Which claim carries the app identity (real Entra tokens)

A real **client-credentials (app-only)** access token — the pattern a service or
agent uses — varies by the resource app's `requestedAccessTokenVersion`:

| Token | `iss` | App-identity claim | `app_displayname` |
|---|---|---|---|
| **v1.0** (default for custom-API resources) | `https://sts.windows.net/<tenant>/` | **`appid`** | usually absent |
| **v2.0** (`requestedAccessTokenVersion: 2`) | `https://login.microsoftonline.com/<tenant>/v2.0` | **`azp`** | usually absent |

Both carry the **calling app registration's client ID** — the stable per-app
identifier. Because the *default* app-only token is **v1 with `appid`** (not
`azp`), use `jwt_app_claim: "auto"`, which resolves `app_displayname → azp →
appid` and therefore works for either token version. Set it explicitly to
`"appid"` or `"azp"` only if you've standardized on one version.

> `aud` is the *resource* (the gateway), identical across all callers — don't
> use it. `oid` is the service-principal object ID, which differs from the
> client ID — avoid it.

### 10.5 Alternative: Tier 1 (pre-injected header)

If a component **upstream of this plugin** already places the app id in a header
— an API-gateway edge, a `request-transformer`, or the calling app itself —
point the plugin at it:

```yaml
  - name: straiker
    config:
      app_id_header: "x-app-id"   # plugin reads this header as the source
      source: "model-gateway"
```

This is the right tool when you control header injection at the edge. It is
**not** what Kong `openid-connect` produces for bearer tokens (see §10.3), so for
the pure-Entra flow prefer Tier 2.

### 10.6 Tier 2 also works with Kong's free `jwt` plugin

The open-source `jwt` plugin (consumer-key model, HS256/RS256) populates the
**same** `kong.ctx.shared.authenticated_jwt_token` field. So `jwt_app_claim`
works identically behind it — useful where Entra/OIDC isn't in play but JWTs are
still validated at the gateway.

### 10.7 How Straiker app profiles are created

Each distinct `source` value auto-creates a Straiker application on its first
request and accumulates traffic under it thereafter:

```
 source = analytics-platform-client-001  ──►  App profile A  (auto-created)
 source = support-agent-client-002        ──►  App profile B  (auto-created)
 source = research-intel-client-003       ──►  App profile C  (auto-created)
 source = model-gateway   (fallback)      ──►  fallback profile (no identity resolved)
```

Each profile has its own Activity feed, controls (detect/block per control),
usage metrics, and per-user attribution.

### 10.8 Verification status

**Verified end-to-end against a live Microsoft Entra tenant** (`openid-connect` +
`ai-proxy-advanced` + straiker on a single Kong route, one Straiker API key):

- A real Entra app-registration token is **validated by Kong against the tenant
  JWKS** — a forged or invalid token is rejected with **HTTP 401** before the
  plugin runs.
- `ai-proxy-advanced` replaces `Authorization` with the provider key (confirmed
  by inspecting the headers visible at the plugin's `access` phase); the caller
  identity nonetheless resolves — proving it comes from shared context (Tier 2),
  not the header.
- The plugin resolves `source` to the calling app's client ID and a distinct
  Straiker app profile is auto-created — with the app sending **only its normal
  Entra bearer token** (no `x-app-id`, no app change).
- Multi-app enumeration (5 distinct identities → 5 distinct Console profiles)
  verified through the single route on one key.

---

## 11. Kong AI Proxy Advanced compatibility (v0.4.0+)

### Why this exists

[Kong AI Proxy Advanced](https://developer.konghq.com/plugins/ai-proxy-advanced/)
(Enterprise) is not a passthrough — it normalizes provider-native requests
(Bedrock, Anthropic, Azure, Gemini, Mistral…) into OpenAI shape, and on the
response path it **owns the response body**: it buffers upstream bytes, runs
format conversion in its own `body_filter`, and for `stream: true` it re-emits
its own OpenAI-format SSE chunks (`data: {…}\n\n`). A naïve guardrail plugin
that reads `ngx.arg[1]` in `body_filter` and decodes the buffer as a single
JSON document sees nothing (race with ai-proxy-advanced's writer) or an SSE
stream that is not valid JSON. Result: `app_response` is empty on the wire,
the Straiker post-call detect call is skipped, and the Console shows
request-only turns.

### What v0.4.0 changes

| Change | Effect |
|---|---|
| `PRIORITY` lowered from `950` → `760` | Plugin runs **after** `ai-proxy-advanced` (PRIORITY 770) in `body_filter`, so we read the already-normalized OpenAI response — not the raw upstream-native bytes. The original client request is still read via `ngx.req.get_body_data()`, which Kong preserves regardless of `kong.service.request.set_raw_body` rewrites. |
| New `ai_proxy_advanced_compat` flag | Default `false` (legacy v0.3.x single-shot JSON decode). Set `true` to enable an SSE-aware accumulator that walks `data:` events, concatenates `choices[0].delta.content` deltas, and unions streamed `tool_calls` indices before posting to `/detect`. |

### Route configuration

```yaml
services:
  - name: openai-via-ai-proxy-advanced
    url: http://placeholder.invalid    # ai-proxy-advanced rewrites the upstream
    routes:
      - name: chat
        paths: [/chat]
    plugins:
      - name: ai-proxy-advanced
        config:
          targets:
            - route_type: llm/v1/chat
              model:
                provider: openai
                name: gpt-4o-mini
                options: { max_tokens: 512 }
              auth:
                header_name: Authorization
                header_value: Bearer ${OPENAI_API_KEY}
      - name: straiker
        config:
          api_key: ${STRAIKER_API_KEY}
          source: "kong-ai-proxy-advanced"
          mode: both
          agentic: false
          threshold: 0.5
          ai_proxy_advanced_compat: true   # <— required for streaming routes
```

### Agentic + ai-proxy-advanced

Set both `agentic: true` and `ai_proxy_advanced_compat: true`. The same
iteration-aware dedupe applies: pre-call only fires when `messages[-1].role`
is `user`; post-call only fires when the streamed final assistant message
carries no `tool_calls`. The SSE accumulator additionally reassembles
streamed `tool_calls` deltas so the `has_tool_calls` signal is correct for
agent-loop iterations that stream their tool calls.

### Operational notes

- The PRIORITY change is permanent (it's set at module load and can't be
  per-route). Existing v0.3.x routes with no other AI plugin on the chain
  will not see a behavior difference — there is no competing `body_filter`
  consumer in that case. If you operate routes with other Kong-shipped AI
  plugins (`ai-prompt-guard` 771, `ai-response-transformer` 768, etc.) and
  rely on a specific ordering, validate with your existing test suite
  before rolling v0.4.0.
- For non-streaming routes (`stream: false`), the flag is a no-op — the
  legacy single-shot JSON decode path runs and is unchanged from v0.3.x.

---

## 12. Deployment patterns & support matrix

Kong runs in four topologies. They differ in **who hosts the data plane** (where
the plugin code executes) and **whether custom plugins are allowed there** — which
determines which Straiker plugin you use.

| Topology | Data plane host | Custom plugins? | Straiker plugin | Streaming to client | Support |
|---|---|---|---|---|---|
| **Self-hosted Kong** (OSS / Enterprise, on-prem or your cloud) | You | Yes (LuaRocks / Docker image / `KONG_PLUGINS`) | **`straiker`** | ✅ Yes | ✅ Full |
| **Konnect + self-managed DP** (hybrid) | You (DP) / Kong (control plane) | Yes (bake into the DP image + register schema on the CP) | **`straiker`** | ✅ Yes | ✅ Full |
| **Konnect Dedicated Cloud Gateways** (full SaaS, prod) | Kong | Yes, **sandboxed** (2 files, no timers, no filesystem) | **`straiker-saas`** | ⚠️ Buffered (no token streaming) | ✅ Full parity for non-streaming |
| **Konnect Serverless Gateways** (full SaaS, dev/free) | Kong | **No** (only bundled plugins) | — | — | ❌ Not supported (custom plugins not allowed) |

**Decision rule:**

- **You manage the data plane** (self-hosted or hybrid) → use **`straiker`**. It's
  the full-feature, streaming-friendly, timer-based build.
- **Kong manages the data plane** (Dedicated Cloud) → use **`straiker-saas`**. It's
  the timer-free, two-file, response-phase build (§13). Streaming is buffered.
- **Serverless Gateways** can't run custom plugins at all — there's no path; move
  the route to a Dedicated Cloud or hybrid gateway.

### 12.1 Self-hosted install

```bash
luarocks install .../kong-plugin-straiker-0.8.0-1.all.rock   # or bake into your Kong Docker image
export KONG_PLUGINS=bundled,straiker
kong reload
```

### 12.2 Konnect hybrid (self-managed data plane)

Two halves: the **data plane** needs the plugin code; the **control plane** needs
the schema so it can validate the plugin config you create.

1. **Bake the plugin into your DP image** (it's a Kong-managed binary you run):
   ```dockerfile
   FROM kong/kong-gateway:3.x
   USER root
   COPY kong/plugins/straiker /usr/local/share/lua/5.1/kong/plugins/straiker
   USER kong
   ```
   Run the DP with `KONG_PLUGINS=bundled,straiker`.
2. **Register the plugin schema on the control plane** so Konnect accepts the
   config (the DP does not auto-advertise custom schemas to Konnect):
   ```bash
   curl -X POST "$KONNECT_ADMIN_API/core-entities/plugin-schemas" \
     -H "Authorization: Bearer $KONNECT_PAT" -H "Content-Type: application/json" \
     -d "{\"lua_schema\": $(jq -Rs . < kong/plugins/straiker/schema.lua)}"
   ```
3. Create routes/services and attach the `straiker` plugin via the Konnect Admin
   API (or the UI) as usual.

### 12.3 Konnect Dedicated Cloud (full SaaS)

Kong runs the data plane, so you can't install a rock or bake an image — you
**upload the two `straiker-saas` files**. See **§13**.

---

## 13. straiker-saas — the Konnect Dedicated Cloud (full SaaS) build

`straiker-saas` is the same guardrail capability rebuilt for Kong's **full-SaaS
Dedicated Cloud Gateways**, where Kong hosts the data plane and runs custom
plugins in a sandbox.

### 13.1 Why it's a separate plugin

1. **The Dedicated Cloud sandbox forbids background timers** (`ngx.timer.at`) and
   `init_worker`. The `straiker` plugin does its post-call detection in a
   log-phase timer (fire-and-forget) — not allowed there.
2. **A Kong plugin can't implement both the `response` phase and
   `body_filter`/`header_filter`** (Kong refuses to start). `straiker` uses
   `body_filter` to accumulate the response, so the response-phase approach has
   to be its own plugin.

`straiker-saas` does everything **synchronously**, with **no timers, no
`body_filter`/`header_filter`, no `init_worker`, no filesystem writes, and no
custom-module requires** — so it loads unmodified on Dedicated Cloud as two
self-contained files (`handler.lua` + `schema.lua`).

### 13.2 How it works

| Phase | What it does |
|---|---|
| **`access`** | Synchronous input guardrail + blocking; app-source resolution (Entra/OIDC JWT claim or header, §10); agentic tool-trace capture from the request `messages[]`; enables buffered proxying. |
| **`response`** | Reads the fully-buffered upstream answer (Kong's [`response` phase](https://developer.konghq.com/gateway/entities/plugin/#response-phase) — the same buffered post-response hook `ai-response-transformer` uses), scores it synchronously, and can **block / replace** it before the client sees it. |

This means `straiker-saas` adds a capability the timer build doesn't have:
**post-call response blocking** (`block_response`). The model's answer is scored
before it reaches the client, and a flagged answer is withheld.

### 13.3 Parity with `straiker`

| Capability | `straiker` (timer) | `straiker-saas` (response phase) |
|---|---|---|
| Pre-call input guardrail + blocking | ✅ | ✅ |
| Agentic tool-trace (full `messages[]`, tool_calls reshaped) | ✅ | ✅ |
| App-source resolution (Entra/OIDC `jwt_app_claim`, `app_id_header`) | ✅ | ✅ |
| Post-call response evaluation (observability) | ✅ (async, fire-and-forget) | ✅ (synchronous, adds latency) |
| **Post-call response blocking** | ❌ | ✅ (`block_response`) |
| Token streaming to client (`stream: true`) | ✅ | ❌ buffered (see §13.5) |
| MCP discovery (preview) | ✅ (off by default) | ❌ (handled server-side) |
| Background timers / `init_worker` | uses a timer | none (sandbox-safe) |

### 13.4 Config differences vs `straiker`

`straiker-saas` keeps the same field names and defaults as `straiker` (so a route
can move between builds with the same config), with these differences:

- **New: `block_response`** (bool, default `false`). When `true` and the model's
  answer scores over `threshold`, the answer is withheld and replaced (403 if
  `verbose_block`, else a safe 200). Default `false` = response is scored for
  visibility only and always forwarded.
- **Removed: `ai_proxy_advanced_compat`**. The response phase reads the buffered
  body directly and auto-detects SSE vs JSON by Content-Type — no flag needed.
- **Removed: the MCP fields** (`mcp_discovery`, `mcp_server_name`, `mcp_source`).

`mode`, `agentic`, `blocking`, `verbose_block`, `threshold`, `timeout`,
`fail_open`, `source`, `destination`, `app_id_header`, `jwt_app_claim`, `api_key`,
`detect_url` all behave exactly as documented for `straiker`.

### 13.5 The streaming trade-off (read this)

Implementing the `response` phase auto-enables **buffered proxying**: Kong holds
the entire upstream response before sending any of it to the client. Consequences:

- **Token streaming (`stream: true`) is buffered** — the client receives the whole
  answer at once at the end, not incrementally. Functionally correct, but it
  defeats the point of streaming.
- **HTTP/2 and gRPC upstreams are not supported** under buffered proxying.
- **Non-streaming JSON responses are unaffected.**

If you need true token streaming to the client, keep that route on a self-hosted
or hybrid gateway with the `straiker` plugin. The `straiker-saas` build is for
Dedicated Cloud, where the timer ban makes the response phase the only way to do
synchronous response evaluation and blocking.

### 13.6 Uploading to a Dedicated Cloud Gateway

The sandbox accepts exactly two files. Upload via the Konnect UI
(**Gateway Manager → your control plane → Plugins → Custom Plugins → New**) or the API:

```bash
curl -X POST "$KONNECT_ADMIN_API/core-entities/custom-plugins" \
  -H "Authorization: Bearer $KONNECT_PAT" -H "Content-Type: application/json" \
  -d "{\"name\":\"straiker-saas\",
       \"handler\": $(jq -Rs . < kong/plugins/straiker-saas/handler.lua),
       \"schema\":  $(jq -Rs . < kong/plugins/straiker-saas/schema.lua)}"
```

Then attach `straiker-saas` to your routes like any other plugin. Place it on a
route alongside `ai-proxy-advanced` (and `openid-connect` for the Entra flow),
exactly as you would `straiker`.

### 13.7 Validation status

Validated on a Konnect self-managed data plane (Kong 3.14) — same runtime as a
Dedicated Cloud gateway, with `ai-proxy-advanced` + `openid-connect` on the route:

- **Response phase + `ai-proxy-advanced` coexist** under buffered proxying — the
  buffered OpenAI answer is read and scored, and the original answer flows through
  unchanged when not blocked.
- **Input blocking, response blocking, agentic tool-trace, diverse/parallel/nested
  tool calls, Entra/OIDC app resolution, Tier-1 header enumeration, multi-model,
  and multi-agent correlation** all verified (37/37 end-to-end checks).
- A real tool-using agent loop (RAG search, DB lookups, calendar/email actions,
  multi-hop and parallel tool calls) routed through the build produced rich
  multi-step Agentic Steps in the Console.

> **One open item for an actual Dedicated Cloud Gateway:** confirm the plugin
> sandbox permits the outbound HTTP client (`resty.http`) in the `response` phase.
> It is loaded lazily and `pcall`-guarded, so a stricter sandbox degrades to
> fail-open rather than failing to load; Kong's own `ai-response-transformer`
> makes outbound calls in this phase, so it is expected to work.

---

## 14. References

- Plugin source: [`kong/plugins/straiker/handler.lua`](kong/plugins/straiker/handler.lua), [`schema.lua`](kong/plugins/straiker/schema.lua)
- SaaS plugin source: [`kong/plugins/straiker-saas/handler.lua`](kong/plugins/straiker-saas/handler.lua), [`schema.lua`](kong/plugins/straiker-saas/schema.lua)
- Public docs: <https://docs.straiker.ai/defend-ai/kong-gateway-integration>
- Detect API reference: <https://docs.straiker.ai/api-reference/defend-ai-api>
- Detect-agentic API reference: <https://docs.straiker.ai/api-reference/defend-ai-api/detect-agentic>
- Plugin GitHub repo & releases: <https://github.com/PhimmStraiker/kong-plugin-straiker>
- Kong openid-connect plugin reference: <https://developer.konghq.com/plugins/openid-connect/>
- Kong jwt plugin reference: <https://developer.konghq.com/plugins/jwt/>
- Azure AD JWT claims reference: <https://learn.microsoft.com/en-us/entra/identity-platform/access-token-claims-reference>
