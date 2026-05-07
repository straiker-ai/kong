# Straiker Kong Plugin — Design, Flow Matrix & Operations

A Lua plugin that runs inside Kong Gateway and calls Straiker
`POST /api/v1/detect` (or `/api/v1/detect?agentic`) on every AI request flowing
through Kong. Intended as the production protection point in front of OpenAI,
Anthropic, Bedrock, etc.

This document is the source of truth on how the plugin behaves. Read sections
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

Recommended install (one command, any Kong instance OSS/Enterprise/Konnect data plane):

```bash
luarocks install https://github.com/PhimmStraiker/kong-plugin-straiker/releases/download/v0.3.1/kong-plugin-straiker-0.3.1-1.all.rock
export KONG_PLUGINS=bundled,straiker     # or in kong.conf
kong reload
```

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
| Adversarial prompt, control in **block** mode | ✅ score=1, blocks | ❌ skipped (request never reached upstream) | **403** | **1** (1 pre, 0 post) | Pre-call turn with prompt + empty response box. Should display block indicator (Eng item — see §6). Body of 403 returned to client carries `turn_id`, `score`, message. |

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

## 6. Open issues for Eng (verified against production app 1614)

These are observations from a 152-turn data export from app 1614 (CSV from `/applications/defend/1614/activity` → Download Prompts). Plugin behavior is correct; the gaps below are on the Straiker side.

### 6.0 `LLM Evasion` (prompt-injection control) over-fires on agentic apps in block mode

**Symptom:** Putting the **LLM Evasion** control in `block` mode on an agentic-type Straiker application produces frequent false positives on benign content. Verified examples that returned `score: 1` from the agentic API with `block.llm_evasion: 1`:

- `"What is 17 times 19 plus 23?"` (math)
- `"How do you say hello in Spanish?"` (translation)
- `"hello"` (one-word greeting)

**Plugin-side behavior is correct:** when Argus returns `score: 1`, the plugin honors it and returns HTTP 403 — verified across 5/5 round-trip tests. **The issue is detection-side**, not gateway-side. Detect mode returns the same violations but does not block, so the FP rate is invisible until block mode is enabled.

**Recommendation for new agentic deployments:**

1. Start with **all controls in detect mode** for the first week of monitoring. Inspect Activity for violation patterns and tune sensitivity per control.
2. Only flip a control to **block mode** after you've reviewed its detect-mode firings on real traffic and confirmed the FP rate is acceptable for that specific app.
3. **Be especially cautious with LLM Evasion in block mode on agentic apps.** It's the single biggest FP risk and will block normal user questions like "what's the weather" or "how do I do X". If you must enable it in block mode, raise the threshold or scope it to a narrow subset of routes first.
4. Customer-facing UX impact of an over-firing control in block mode is severe — every blocked request returns HTTP 403 to the end user with no model response. Validate carefully before enabling.

This is an Eng / detection-tuning concern. The plugin and its Argus integration are working as designed; tuning belongs to the Detection / Models team.

### 6.1 `user_name` is dropped on the agentic ingest path

**Symptom:** Every persisted turn record on `/detect?agentic` has `user_name = "user"` literal, regardless of what the plugin sent in `metadata.user_name` or top-level `user_name`. Confirmed across 152 turns: **152/152 have `user_name = "user"`**, despite payloads carrying `alice@acme.com`, `dan@acme.com`, `clean-user-1778176029@acme.com`, etc.

**Plugin-side proof:** plugin debug logs show outgoing payloads with the correct identity. Direct API probes (no Kong, no plugin) bypassing the gateway also persist as `user_name = "user"` — so this is purely an agentic ingest issue, not a plugin issue. Standard `/detect` (non-agentic) preserves `user_name` correctly.

**Impact:** No per-user attribution on agentic turns. UBA, forensics, per-user policy all useless on agentic apps until fixed.

**Test turn IDs to investigate:**
- `pf-a3fa5802-d8e7-4e86-9489-19608ab35e86` — sent `metadata.user_name: "schema-verify-zachary@acme.com"`
- `pf-e2df3162-3c61-4f71-9446-202b170c0e3a` — sent top-level `user_name: "schema-verify-yoshi@acme.com"`

### 6.2 Block-mode triggers don't render distinctly in Console Activity

**Symptom:** When a control is in `block` mode and fires, the gateway correctly returns HTTP 403 with `score: 1` in the API response. The persisted Turn record exists with the right prompt and metadata. **But the Activity row shows no visual distinction from a benign turn** — no "blocked" badge, no red label, no shield icon. The empty assistant-response box is the only hint.

In contrast, `detect`-mode triggers correctly render their violation badge (e.g. "LLM Evasion" in red) on the Activity row.

**Impact:** Security teams reviewing Activity can't distinguish a block from a hung benign request. Demo confusion (the customer's first reaction was "did the model not answer?").

**Ask:** Add a `[BLOCKED]` chip or red border to Activity rows where the API call to `/detect?agentic` resulted in `score_block > 0`, separate from in-detect-mode tag rendering.

### 6.3 Block-mode trigger details may not be persisted into the Turn verdict

**Symptom (needs Eng confirmation, not certain):** Looking at the debug panel of a turn that we *know* was blocked at the gateway (HTTP 403, plugin received `score: 1` from the API), the persisted Turn shows `score: 0`, `score_block: 0`, `verdict.detections: []`. The block decision came back to the plugin instantly but doesn't seem reflected in the indexed record.

**Caveat:** `phimm@straiker.ai` (the user) reasonably pushed back on this, saying architecturally Argus should record what it returned. So it's possible the Console UI reads from a partial projection that doesn't include block-mode results, while the underlying record is correct. **Eng to confirm whether the indexed Turn does or doesn't reflect block-mode triggers**, and if not, fix or document the projection mismatch.

The `/api/v1/score?turn_id=…` lookup endpoint returns 404 for `pf-`-prefixed agentic turn IDs (it expects UUID4), so this can't be independently verified outside the Console UI today. Adding agentic-ID support to the score endpoint would help.

### 6.4 Multi-turn sessions need explicit `x-session-id` from the client

**Symptom:** All 152 turns in the export had distinct `session_id` values. None grouped into multi-turn sessions even though some were multi-iteration agent loops or multi-prompt conversations.

**Cause:** The plugin's `session_id` resolution is `x-session-id header → ngx.var.request_id → "kong-session"`. `ngx.var.request_id` is per-Kong-request, not per-conversation, so without an explicit header the plugin reports each request as a fresh session.

**Customer guidance (already in the plugin docs):** Have the calling app always set `x-session-id` to a stable value for one logical conversation. The doc tells them to do this, but it's worth flagging as a real-world gotcha — if they don't, they lose multi-turn correlation in the Console.

---

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

---

## 10. References

- Plugin source: [`kong/plugins/straiker/handler.lua`](kong/plugins/straiker/handler.lua), [`schema.lua`](kong/plugins/straiker/schema.lua)
- Multi-agent demo client: [`multi_agent_trace.py`](multi_agent_trace.py)
- Single-agent test client: [`agentic_test.py`](agentic_test.py)
- Public docs: <https://docs.straiker.ai/defend-ai/kong-gateway-integration>
- Detect API reference: <https://docs.straiker.ai/api-reference/defend-ai-api>
- Detect-agentic API reference: <https://docs.straiker.ai/api-reference/defend-ai-api/detect-agentic>
- Plugin GitHub repo & releases: <https://github.com/PhimmStraiker/kong-plugin-straiker>
