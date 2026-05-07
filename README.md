# Straiker Kong Plugin — Design & Operations Notes

A Lua plugin that runs inside Kong Gateway and calls Straiker
`POST /api/v1/detect` (or `/api/v1/detect?agentic`) on every AI request flowing
through Kong. Intended as the production protection point in front of OpenAI,
Anthropic, Bedrock, etc.

This document covers the design decisions a model-gateway operator needs to
understand before deploying the plugin — most importantly, why agentic apps
behave differently from chatbots and how to configure each.

---

## 1. Plugin install vs. plugin attachment

Kong separates **what the plugin is** from **where it runs**:

| Concept | Where it lives | Set once, or per route? |
|---|---|---|
| Plugin install (the code) | `/opt/kong/plugins/straiker/{handler,schema}.lua` | Once per Kong instance |
| Plugin **attachment** (the config) | `kong.yml` services/routes block, or Admin API | Per route — each attachment gets its own `config: { ... }` |

The `agentic` flag, the API key, the threshold, the mode — all of it lives on
the attachment. One Kong install can attach the plugin to a chatbot route with
`agentic: false` and to an agent route with `agentic: true` simultaneously.
Two routes, two configs, two Straiker apps in the Console.

```yaml
services:
  - name: chatbot
    url: https://api.openai.com
    routes: [{paths: [/chatbot]}]
    plugins:
      - {name: straiker, config: {api_key: "...", agentic: false, mode: "both"}}

  - name: support-agent
    url: https://api.openai.com
    routes: [{paths: [/support-agent]}]
    plugins:
      - {name: straiker, config: {api_key: "...", agentic: true,
                                  source: "Support Agent",
                                  destination: "api.openai.com"}}
```

---

## 2. Agentic vs non-agentic — what changes

The single config flag `agentic: true|false` changes four things:

| Behavior | `agentic: false` (chatbot) | `agentic: true` (agent) |
|---|---|---|
| Straiker endpoint | `POST /api/v1/detect` | `POST /api/v1/detect?agentic` |
| Request body shape | `prompt` + `app_response` strings | full OpenAI `messages[]` array |
| Pre-call hook (block before upstream) | runs on every request | **skipped** (see §3) |
| Post-call hook (observability) | runs on every response | runs only on the final-answer iteration of an agent loop |
| Detection categories | full standard catalog (PII split input/output, custom controls, payment, third_party) | agentic-only controls (tool_misuse, malicious_user_session, improper_output_handling, hallucination_in_rag) |

The choice depends on how the customer's app talks to OpenAI. See §6.

---

## 3. Why agentic mode runs post-call only

A standard chatbot is one HTTP call: `user prompt → response`. Pre-call gates
the prompt; post-call captures the response. Two hooks, two real value-adds.

An **agent** loops:

```
client → OpenAI: messages = [system, user]
OpenAI → client: assistant.tool_calls = [...]      ← intermediate
client runs the tool
client → OpenAI: messages = [..., tool_result]
OpenAI → client: assistant.tool_calls = [...]      ← intermediate
client runs the tool
client → OpenAI: messages = [..., tool_result_2]
OpenAI → client: assistant.content = "..."         ← final answer
```

Kong sees **N** sequential calls for **one** logical user interaction. If the
plugin fires both pre-call and post-call on each iteration:

- Pre-call iter 1 — fine (real user input)
- Pre-call iter 2 — duplicate; just a tool result coming back, not new input
- Pre-call iter N — duplicate
- Post-call iter 1..N-1 — empty assistant content (model is calling tools, not answering)
- Post-call iter N — full final answer

That's the source of the "before/after blank" duplicates customers see in the
Console. **Same problem Portkey hit at Coupang.**

The plugin's rule: when `agentic: true`, **skip pre-call entirely** and only
fire post-call on the iteration where the model returns final assistant content
(no `tool_calls`). One logical interaction → one Straiker turn per OpenAI hop,
each carrying the full conversation history up to that point.

Pre-call gating still runs for chatbot-style routes (`agentic: false`). It is
specifically the agent-loop case where pre-call is noise without protective
value — by the time the agent's loop is running, the request has already been
inside the customer's app process.

If a customer needs *first-input* gating on an agent (rare; usually handled
inside the app), they can attach a second non-agentic route just for that,
or run a separate edge plugin upstream of Kong.

---

## 4. Schema — what the plugin sends to Straiker

### Standard `/api/v1/detect`

```json
{
  "prompt":       "<last user message>",
  "app_response": "<assistant's content>",
  "rag_content":  "N/A",
  "session_id":   "...",
  "user_name":    "...",
  "user_role":    "...",
  "metadata": {
    "session_id": "...",
    "user_name":  "...",
    "user_role":  "...",
    "remote_ip":  "...",
    "app_name":   "<plugin source>",
    "source":     "kong-plugin",
    "trace_id":   "<x-trace-id header>",
    "agent_role": "<x-agent-role header>"
  },
  "network":      { "IP": "...", "User-Agent": "...", "Content-Type": "..." },
  "annotations":  { "source": "kong-plugin", "model": "...", "hook": "post_call",
                    "trace_id": "...", "agent_role": "..." }
}
```

### Agentic `/api/v1/detect?agentic`

Same envelope, plus a flat OpenAI-style `messages[]`:

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
                     "content": "{\"customer\": \"...\"}"},
    {"role": "assistant", "content": "Your order shipped on Tuesday."}
  ],
  "session_id":   "...",
  "user_name":    "...",
  "metadata":     { /* same envelope as above */ },
  "annotations":  { /* same as above */ }
}
```

### Tool-call reshape

OpenAI returns:

```json
{"id": "...", "type": "function",
 "function": {"name": "...", "arguments": "<stringified-json>"}}
```

Straiker's agentic API expects:

```json
{"id": "...", "name": "...", "input": <parsed object>}
```

The plugin reshapes on the wire. Without this, the Console can't render tool
names or arguments because it looks up `name` and `input` directly on each
tool_call entry.

---

## 5. Identity, session, and trace correlation

The plugin resolves a `user_name` for every request by walking a fallback
chain. Higher-trust sources win:

1. **`x-user-name` header** — set by an upstream identity gateway. Recommended.
2. **Kong consumer** — if Kong's `key-auth`, `jwt`, or `oauth2` plugins
   authenticated the call, `consumer.username` (or `custom_id`) is used.
3. **OpenAI `user` field** in the request body (the standard
   `{"user": "<id>"}` field used for OpenAI's own abuse tracking).
4. Fallback: literal `kong`.

Two additional headers stitch a multi-step / multi-agent interaction into a
single trace in the Console:

| Header | Purpose |
|---|---|
| `x-session-id` | Stable identifier for one logical user conversation. Same value across every Kong → OpenAI hop in that conversation. |
| `x-trace-id` | Optional second correlator; useful if the customer already issues W3C trace IDs from their agent runtime. |
| `x-agent-role` | Free-form label (e.g. `researcher`, `writer`) so multi-agent flows can be visually distinguished in the Console. |

A multi-agent / multi-model interaction (one user prompt → researcher agent on
gpt-4o-mini → writer agent on gpt-4o) becomes **N Straiker turns sharing one
`session_id`**, each tagged with its `agent_role` and `model`. Filter Activity
by `session_id` to see the whole timeline.

---

## 6. What Kong actually sees on the wire

Kong is a passive observer of `POST /v1/chat/completions`. The visibility you
get from the agentic mode depends entirely on how the customer's app talks to
OpenAI:

| Customer architecture | Kong sees | Use `agentic` mode? |
|---|---|---|
| Single-shot chat (RAG / lookups happen inside the app, then one OpenAI call) | One request per user turn, no tool_calls in the body | **No.** `agentic: false`; richer detection catalog applies. |
| Tool / function calling at the OpenAI boundary (LangChain, OpenAI Agents SDK, custom loops) | N sequential requests per user turn, full tool_calls + tool results in `messages[]` | **Yes.** `agentic: true`; full agent trace in the Console. |
| Streaming responses (`stream: true`) | Pre-call still works; post-call body capture currently doesn't parse SSE | Agentic post-call hook will silently no-op; pre-call gating still fine. |
| OpenAI Assistants / Responses API (stateful threads) | Different URL paths and IDs (`thread_id`, `previous_response_id`) — the plugin only handles Chat Completions today | Out of scope for current plugin version. |

Recommend a **canary capture** before flipping anything to block: deploy with
`mode: post_call`, `threshold: 1.0` (never blocks), send 50–100 real
production turns, inspect 10 random ones in the Console. Confirm Agentic Steps
shows tool calls and tool results before tightening.

---

## 7. Operational gotchas

- **Response decompression.** OpenAI returns `Content-Encoding: gzip` (or `br`)
  by default. The plugin's `body_filter` buffers raw bytes; gzipped bytes don't
  parse as JSON. The plugin sets `Accept-Encoding: identity` on the upstream
  request so OpenAI returns plain JSON. Without this, post-call captures the
  prompt but not the response.
- **Cosockets in `body_filter`.** Kong forbids cosocket I/O (HTTP requests) in
  the body_filter phase. The plugin defers post-call detection to
  `ngx.timer.at(0, …)` from the log phase, where cosockets are allowed.
- **`Content-Length` rewrite.** The plugin clears `ngx.header.content_length`
  in `header_filter` so the buffered body can be re-emitted unchanged after
  inspection.
- **Payload logging.** The plugin logs the outgoing Straiker payload at
  `DEBUG` level only. Production deployments do not write user prompts (or any
  PII therein) to nginx access logs by default.
- **DB-less Kong reload.** Use `curl -X POST http://localhost:8001/config -F
  config=@kong.yml` to hot-apply schema changes; `PATCH` is not supported.
- **`api_key` storage.** Declared `encrypted = true` and `referenceable =
  true`, so Kong stores it encrypted at rest and resolves `{vault://...}`
  references for production deployments.

---

## 8. Configuration reference

| Field | Default | Description |
|---|---|---|
| `api_key` | (required) | Straiker Defend AI API key. Encrypted at rest. |
| `detect_url` | `https://api.prod.straiker.ai/api/v1/detect` | Straiker endpoint. Override for regional deployments. |
| `mode` | `both` | `pre_call`, `post_call`, or `both`. Ignored on agentic — agentic always runs post-call only. |
| `agentic` | `false` | When `true`, calls `/detect?agentic`, forwards full `messages[]` (tool_calls included), runs post-call only. |
| `source` | `kong-plugin` | Agentic application name. Must match an existing agentic Straiker app, otherwise a new one auto-creates on first request. |
| `destination` | `api.openai.com` | Upstream provider hostname, recorded in agentic detection metadata. |
| `threshold` | `0.5` | Minimum score to block. Higher = more permissive. |
| `timeout` | `5000` | Straiker call timeout in milliseconds. |
| `fail_open` | `false` | When `true`, allow traffic through if Straiker is unreachable. |

---

## 9. Quick decision matrix

> "Should I configure `agentic: true` for this route?"

```
Does the customer's app use OpenAI tool / function calling?
├── No  → agentic: false. Pre-call + post-call on every request.
│         Get the full standard control catalog (input/output PII split,
│         custom controls, payment, third_party, llm_evasion, etc.).
│
└── Yes → agentic: true. Post-call only, deduped to final iteration.
          Tool calls and tool results render in Console "Agentic Steps".
          Get agentic-only controls (tool_misuse, malicious_user_session,
          improper_output_handling, hallucination_in_rag).
```

If unsure, start with `agentic: false, mode: post_call, threshold: 1.0`,
inspect a week of traffic, then promote agent routes to `agentic: true` once
you confirm the calls actually carry `messages[]` with tool_calls in them.

---

## 10. References

- Plugin source: [`kong/plugins/straiker/handler.lua`](kong/plugins/straiker/handler.lua), [`schema.lua`](kong/plugins/straiker/schema.lua)
- Multi-agent demo client: [`multi_agent_trace.py`](multi_agent_trace.py)
- Single-agent test client: [`agentic_test.py`](agentic_test.py)
- Public docs: <https://docs.straiker.ai/defend-ai/kong-gateway-integration>
- Detect API reference: <https://docs.straiker.ai/api-reference/defend-ai-api>
- Detect-agentic API reference: <https://docs.straiker.ai/api-reference/defend-ai-api/detect-agentic>
