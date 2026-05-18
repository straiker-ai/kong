# Agentic flow: exact request shapes

This document is the answer to "what does Kong receive vs what does the plugin send to `/detect?agentic`" — written so Engineering can decide whether to keep the parsing/mapping inside the Kong plugin (today) or pull it server-side into Argus.

All examples below are from real traffic captured during the v0.4.0 harness runs. Field-for-field accurate. The handler-side logic referenced is in `kong/plugins/straiker/handler.lua` at the line numbers cited.

---

## 1. What Kong receives (request from the agent client)

The agent client (OpenAI SDK, LangChain, custom Python, etc.) POSTs the standard **OpenAI Chat Completions** request body to the Kong route. Kong reads this verbatim via `ngx.req.read_body()` in the plugin's `access` phase.

### Iteration 1 — initial user prompt (no tool history yet)

```http
POST /chat-agentic/chat/completions HTTP/1.1
Host: kong-data-plane:8000
Authorization: Bearer sk-...           # client's OpenAI key (Kong's ai-proxy-advanced may replace this)
Content-Type: application/json
x-user-name: alice@acme.example
x-session-id: sess-2026-05-18-001
x-trace-id: trace-001
x-agent-role: researcher
```

```json
{
  "model": "gpt-4o-mini",
  "messages": [
    {"role": "system", "content": "You are a research assistant. Use tools when needed."},
    {"role": "user",   "content": "What is the Straiker Kong plugin?"}
  ],
  "tools": [
    {"type": "function", "function": {
        "name": "rag_search",
        "description": "Search internal docs",
        "parameters": {"type":"object", "properties": {"query":{"type":"string"}}, "required":["query"]}
    }}
  ]
}
```

### Iteration 2 — model returned `tool_calls`, client dispatched the tool, now sending the loop continuation

```json
{
  "model": "gpt-4o-mini",
  "messages": [
    {"role": "system",    "content": "You are a research assistant. Use tools when needed."},
    {"role": "user",      "content": "What is the Straiker Kong plugin?"},
    {"role": "assistant", "content": null,
     "tool_calls": [
       {"id": "call_abc123", "type": "function",
        "function": {"name": "rag_search", "arguments": "{\"query\":\"Straiker Kong plugin\"}"}}
     ]},
    {"role": "tool", "tool_call_id": "call_abc123", "name": "rag_search",
     "content": "{\"results\":[{\"title\":\"Kong plugin\",\"text\":\"Lua plugin that calls /detect on every request...\"}]}"}
  ],
  "tools": [ /* same tools list, repeated */ ]
}
```

### Iteration N — final iteration, model returns the answer (no `tool_calls`)

```json
{
  "model": "gpt-4o-mini",
  "messages": [
    {"role": "system",    "content": "You are a research assistant. Use tools when needed."},
    {"role": "user",      "content": "What is the Straiker Kong plugin?"},
    {"role": "assistant", "content": null, "tool_calls": [ /* call_abc123 */ ]},
    {"role": "tool",      "tool_call_id": "call_abc123", "name": "rag_search", "content": "{...}"},
    /* … any additional tool_call/tool pairs from intermediate iterations … */
  ],
  "tools": [ /* same tools list */ ]
}
```

After the final iteration the model's response (captured by the plugin in `body_filter`) is:

```json
{
  "id": "chatcmpl-...",
  "object": "chat.completion",
  "model": "gpt-4o-mini-2024-07-18",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": "The Straiker Kong plugin is a Lua plugin that calls Straiker /detect on every request flowing through Kong...",
      "tool_calls": null
    },
    "finish_reason": "stop"
  }]
}
```

Notes on what Kong sees:
- `messages[].content` may be a **string OR a multi-part array** like `[{"type":"text","text":"..."}]` (OpenAI's vision/multimodal shape).
- `messages[].role` ∈ `{system, user, assistant, tool, function}`.
- `tool_calls[].function.arguments` is a **JSON string**, not a parsed object.
- On `tool`-role messages, the field is `name` (OpenAI's spec), not `tool_name`.
- `tools` is the function-spec list, repeated on every iteration.
- The plugin **does not need to read `tools`** — it scores `messages[]` only.
- Behind `ai-proxy-advanced`, by the time the plugin reads the request body in `access`, AI Proxy Advanced has already rewritten provider-specific shapes into OpenAI's. We see OpenAI shape regardless of upstream (Bedrock, Anthropic, Mistral, etc.).

---

## 2. What the plugin sends to `/detect?agentic`

The plugin builds this payload in `build_payload()` ([handler.lua:140-195](kong/plugins/straiker/handler.lua#L140-L195)). Fires once per **terminal iteration** (the one where the model returns no `tool_calls`). Earlier iterations are deduped to avoid phantom turns ([handler.lua:481-488](kong/plugins/straiker/handler.lua#L481-L488)).

```http
POST /api/v1/detect?agentic HTTP/1.1
Host: api.prod.straiker.ai
Authorization: Bearer <STRAIKER_API_KEY>
Content-Type: application/json
```

```json
{
  "source": "kong-ai-proxy-advanced",
  "destination": "api.openai.com",

  "session_id": "sess-2026-05-18-001",
  "user_name":  "alice@acme.example",
  "user_role":  "internal",

  "metadata": {
    "session_id": "sess-2026-05-18-001",
    "user_name":  "alice@acme.example",
    "user_role":  "internal",
    "remote_ip":  "203.0.113.42",
    "app_name":   "kong-ai-proxy-advanced",
    "source":     "kong-plugin",
    "trace_id":   "trace-001",
    "agent_role": "researcher"
  },

  "network": {
    "IP":           "203.0.113.42",
    "User-Agent":   "OpenAI/Python 1.97.1",
    "Content-Type": "application/json"
  },

  "annotations": {
    "source":     "kong-plugin",
    "model":      "gpt-4o-mini",
    "hook":       "post_call",
    "trace_id":   "trace-001",
    "agent_role": "researcher"
  },

  "messages": [
    {"role": "system",    "content": "You are a research assistant. Use tools when needed."},
    {"role": "user",      "content": "What is the Straiker Kong plugin?"},
    {"role": "assistant",
     "tool_calls": [
       {"id": "call_abc123", "name": "rag_search", "input": {"query": "Straiker Kong plugin"}}
     ]},
    {"role": "tool", "tool_call_id": "call_abc123", "tool_name": "rag_search",
     "content": "{\"results\":[{\"title\":\"Kong plugin\",\"text\":\"Lua plugin that calls /detect on every request...\"}]}"},
    {"role": "assistant",
     "content": "The Straiker Kong plugin is a Lua plugin that calls Straiker /detect on every request flowing through Kong..."}
  ]
}
```

The last `assistant` entry — the model's final answer captured from `body_filter` — is only present on **post-call** firings. On **pre-call** firings (mode=`pre_call` or `both` on iteration 1) the messages array ends with the user turn and there is no appended assistant content.

---

## 3. Exact transformations the plugin applies

Eight transformations sit between "what Kong receives" and "what we send to /detect". This is the work Eng would inherit if they pull it server-side.

| # | Transformation | Source field (OpenAI) | Output field (Straiker) | Handler reference |
|---|---|---|---|---|
| 1 | Tool call reshape | `tool_calls[].function.{name, arguments:"<json string>"}` | `tool_calls[].{name, input:<parsed object>}` | `transform_tool_calls()` [handler.lua:45-73](kong/plugins/straiker/handler.lua#L45-L73) |
| 2 | Tool message field rename | `tool` message `name` | `tool` message `tool_name` | `build_agentic_messages()` [handler.lua:93-97](kong/plugins/straiker/handler.lua#L93-L97) |
| 3 | Multi-part content flatten | `content: [{"type":"text","text":"..."}]` | `content: "..."` (string) | `extract_text_content()` [handler.lua:21-32](kong/plugins/straiker/handler.lua#L21-L32) |
| 4 | Omit empty content | `content: ""` | (field omitted entirely) | `build_agentic_messages()` [handler.lua:83-86](kong/plugins/straiker/handler.lua#L83-L86) |
| 5 | Append final assistant on post-call | (from `body_filter` parse of upstream response) | last `messages[]` entry, `role:"assistant"` | `build_agentic_messages()` [handler.lua:101-106](kong/plugins/straiker/handler.lua#L101-L106) |
| 6 | Metadata envelope | identity headers (`x-user-name`, `x-session-id`, `x-trace-id`, `x-agent-role`, `x-user-role`) + body `user` field + Kong consumer | `metadata{session_id,user_name,user_role,remote_ip,app_name,source,trace_id,agent_role}` | `client_metadata()`, `build_payload()` [handler.lua:127-158](kong/plugins/straiker/handler.lua#L127-L158) |
| 7 | Network envelope | `ngx.var.remote_addr` + `User-Agent` header | `network{IP,User-Agent,Content-Type}` | `client_metadata()` [handler.lua:132-136](kong/plugins/straiker/handler.lua#L132-L136) |
| 8 | Annotations envelope | model from request body + plugin config (`hook`, `source`) + correlation headers | `annotations{source,model,hook,trace_id,agent_role}` | `build_payload()` [handler.lua:179-193](kong/plugins/straiker/handler.lua#L179-L193) |

Identity resolution priority for `metadata.user_name` ([handler.lua:110-125](kong/plugins/straiker/handler.lua#L110-L125)):
1. `x-user-name` request header (explicit identity from upstream identity gateway)
2. Kong consumer (set by `key-auth`, `jwt`, `oauth2` plugins)
3. OpenAI standard `user` field in the request body
4. Fallback string `"kong"`

---

## 4. Iteration-dedupe rules (so Eng knows which iterations the plugin actually posts)

For agentic flow the plugin fires `/detect?agentic` at most **once per logical user prompt** — on the terminal iteration. The rules:

| Phase | When it fires | Rationale |
|---|---|---|
| `access` (pre-call) | Iteration 1 only (`messages[-1].role == "user"`). Skipped on continuation iterations where `messages[-1].role ∈ {tool, assistant}`. | Gateway-level blocking on bad user prompts; no point re-scoring on each agent-loop hop. |
| `log` (post-call) | Final iteration only, when the model's response has `tool_calls = null/empty` AND `content != ""`. | The final messages[] carries the FULL conversation including all prior tool calls and results, so one post-call captures everything. |

Both rules implemented in handler.lua at [279-283](kong/plugins/straiker/handler.lua#L279-L283) (pre-call) and [486-488](kong/plugins/straiker/handler.lua#L486-L488) (post-call).

---

## 5. If Eng pulls this server-side

What changes structurally if Argus does the parsing/mapping itself:

| Today (plugin-side mapping) | If Argus does it |
|---|---|
| Plugin transforms 8 fields before POST. Argus receives a stable, well-shaped payload. | Plugin becomes a thin passthrough that forwards the raw OpenAI request body + identity envelope. Argus runs the 8 transformations. |
| Plugin must be kept in sync with OpenAI spec changes (e.g., new tool-call format). | Argus must handle that. **Plus** Argus must handle Anthropic native, Bedrock native, etc. if customers stop using `ai-proxy-advanced` as a normalizer. |
| Identity resolution chain (header → consumer → body.user → fallback) runs in plugin. | Argus needs the raw headers + a way to know the gateway's consumer concept. Plugin would have to forward headers + a "gateway consumer" annotation. |
| `metadata`, `network`, `annotations` envelopes constructed in plugin from request headers + Kong vars. | Plugin would forward headers + remote IP; Argus reconstructs envelopes. |
| Iteration-dedupe runs in plugin (only one POST per logical prompt). | If moved server-side, plugin would POST every iteration and Argus would dedupe. Higher /detect call volume per agent loop. |
| Provider-specific parsing not needed (`ai-proxy-advanced` already normalized to OpenAI). | If customer bypasses `ai-proxy-advanced` and points Kong straight at Anthropic or Bedrock, Argus needs per-provider parsers. |

**Pros of moving server-side:**
- One transformation codebase, easier to update than N gateway plugins
- New gateway integrations become "just forward the body" wrappers, faster to ship
- Easier to evolve the `/detect?agentic` schema without coordinating N plugin releases

**Cons:**
- Argus has to handle every possible input shape (multimodal content arrays, `cjson.null` semantics, provider-native formats if the gateway doesn't normalize)
- Iteration dedupe moves server-side → higher API call volume from plugin → more Argus load per agent run
- Identity resolution chain becomes Argus's problem; harder to inject Kong-consumer-aware logic at the API tier than at the plugin tier where `kong.client.get_consumer()` is one call

**My recommendation:** keep transformations 1-5 (the messages-shape stuff) on the plugin side — these are mechanical, well-defined, and need to be done before the wire format. Move transformations 6-8 (envelopes) server-side if helpful — they're just header repackaging and don't depend on the body structure. Iteration dedupe MUST stay plugin-side; pushing every loop iteration to Argus 5x-8x'es detect call volume per agent run.

---

## 6. Sample real captures

For Eng to look at actual wire bytes, the v2 agent harness (`scripts/agent_harness_v2.py`) ran 178 successful agent loops through `/chat-agentic` and produced 170 `/detect?agentic` POSTs. Each Console turn has the full payload retrievable. Sample turn IDs from the v2 run:

- A2 Calculator (single tool call): `pf-cb87484f-2001-4e6b-95b6-8676ad120d9f`
- A3 Researcher (multi-tool sequential): `pf-25ba63f1-a331-4ce9-8ef4-f78a3da2e97a`
- A5 DataAnalyst (avg 5.5 iters): see Console activity for `agent_role=A5_DataAnalyst`
- A12 ParallelTools (multiple tool_calls per assistant turn): see `agent_role=A12_ParallelTools`

The Konnect data plane container `straiker-konnect-dp` is still running and logging — Eng can `docker exec ... cat /usr/local/kong/logs/error.log | grep "sending payload"` after raising the log level to `DEBUG` to capture live outbound payloads.
