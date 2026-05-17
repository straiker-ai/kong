# Agent Testing Coverage — v0.4.0 Kong AI Proxy Advanced compatibility

This document records the systematic agent-typology testing executed against
the v0.4.0 Straiker Kong plugin running behind `ai-proxy-advanced` on Kong
Konnect (self-hosted hybrid data plane). All traffic routes through
`http://localhost:8000/chat-agentic` with the plugin attached
(`agentic=true, ai_proxy_advanced_compat=true, mode=post_call`).

## Agent typology (12 personas)

| # | Persona | System persona | Tools | Patterns under test |
|---|---|---|---|---|
| A1 | **Chat** | Concise factual assistant, no tools | — | Pure chat completion / no-tool baseline |
| A2 | **Calculator** | Math assistant, always uses calc | `calc` | Single-tool, single-call iteration |
| A3 | **Researcher** | Multi-source researcher | `rag_search`, `web_search`, `web_fetch` | Multi-tool sequential, source citing |
| A4 | **CustomerSupport** | Support agent | `crm_lookup`, `jira_create`, `send_email` | Action-taking write tools (mutations) |
| A5 | **DataAnalyst** | SQL + chart agent | `sql_query`, `chart_render` | Structured I/O, data ⇒ viz |
| A6 | **CodeAssistant** | Coding agent | `python_exec`, `file_read`, `file_write` | Code-interpreter pattern, filesystem ops |
| A7 | **TravelPlanner** | Multi-API booking agent | `flight_search`, `hotel_search`, `weather`, `book_flight` | Long multi-API tool chains, bookings |
| A8 | **FinancialAdvisor** | Finance research agent | `stock_price`, `calc`, `news_search` | Domain-specific tools + arithmetic |
| A9 | **Supervisor** | Hierarchical orchestrator | `delegate_to_specialist` | Multi-agent delegation, agent-of-agents |
| A10 | **Adversarial** | Constrained assistant under attack | `web_search` (for context) | Prompt injection / jailbreak / SP leak / DAN attempts |
| A11 | **LongContext** | Thorough analyst, RAG-heavy | `rag_search`, `web_search`, `web_fetch` | Deep multi-iteration loops (large messages[]) |
| A12 | **ParallelTools** | Parallel function calls | `weather`, `stock_price`, `calc` | OpenAI parallel tool_calls in a single assistant turn |

## Volume

- **180 distinct prompts** across the 12 personas
- Each prompt drives one full agent loop (~1–8 OpenAI iterations)
- Total Kong→OpenAI hops typically **400–700** (tool-calling iterations + finals)
- One Straiker Console turn per **final assistant iteration** (agentic-mode dedupe is by design)
- Target: **~180 Console post-call events**

## What each test surfaces for the Straiker plugin

| Test dimension | Plugin behavior validated |
|---|---|
| Non-streaming JSON responses | Single-shot JSON decode path, content extraction |
| Multi-iteration agent loops | Iteration-aware dedupe (only final iter fires post-call) |
| Tool calls (single, sequential, parallel) | `tool_calls` reshape (OpenAI nested → Straiker flat), correct `has_tool_calls` skip during intermediate iterations |
| Large request bodies (>8KB) | `client_body_buffer_size` fallback (read from `ngx.req.get_body_file()`) |
| Gzip-compressed responses from ai-proxy-advanced | `kong.tools.gzip.inflate_gzip` inflation before JSON parse |
| `tool_calls: null` final messages | `cjson.null` sentinel handling (not treated as truthy) |
| Adversarial prompts | Pre/post-call detection on injection patterns; tenant-control routing |
| Multi-agent delegation | `agent_role` header propagation per delegated call |

## Critical bugs found and fixed during this run

Three bugs surfaced under the v2 harness that the v0.3.x manual smoke tests
never exercised. All three could silently drop Console turns from real
agentic deployments:

1. **`cjson.null` truthiness on `tool_calls`** — `cjson.safe` decodes JSON
   `null` to a non-nil userdata sentinel. The check
   `msg.tool_calls ~= nil` was true even when the field was JSON null, so
   final-iteration responses (which OpenAI returns with `tool_calls: null`)
   were wrongly tagged as "still calling tools" and the post-call detect
   was silently skipped. **Fix:** explicit `type(tcs) == "table" and #tcs > 0`.

2. **`client_body_buffer_size` body-to-tempfile** — Multi-iteration agent
   loops grow `messages[]` past Kong's default 8 KiB request-body buffer.
   `ngx.req.get_body_data()` returned nil; our access phase silently bailed.
   **Fix:** fall back to `ngx.req.get_body_file()` and read the tempfile.

3. **Gzip-compressed response body** — `ai-proxy-advanced` does NOT honor
   the client's `Accept-Encoding: identity` override (which v0.3.x relied on
   for direct OpenAI traffic). It forwards OpenAI's gzipped response bytes
   unchanged through Kong's response pipeline. Our `body_filter` saw 0x1f8b…
   garbage and `cjson.decode` returned nil, leaving `app_response = ""`.
   **Fix:** detect Content-Encoding=gzip (or magic bytes) in `header_filter`,
   inflate with `kong.tools.gzip.inflate_gzip` in `body_filter` before
   parsing. Response bytes to the client are still passed through unchanged
   (we only inflate for inspection).

All three are required for v0.4.0 to work in real customer deployments behind
ai-proxy-advanced. The v0.3.x manual smoke tests passed because they hit
short messages (no tempfile), didn't trigger gzip on direct OpenAI, and
didn't see `tool_calls: null` (just final content with the field omitted).

## Harness driver

`scripts/agent_harness_v2.py` is the canonical driver. To re-run:

```bash
cd kong-plugin-straiker
set -a; source ./.env.konnect; set +a
export KONG_BASE="http://localhost:8000/chat-agentic"
python3 -u scripts/agent_harness_v2.py | tee run.log
```

All tools are MOCKED — no external services required. The mocks return
deterministic structured data that drives the model to a reasonable final
answer in 1–6 iterations.

## Console verification

After a run, in Straiker Console → app **kong-ai-proxy-advanced** → Activity:

- ~180 distinct Console turns (1 per prompt)
- Each turn shows full agentic-step structure (User → tool(s) → Assistant)
- Filterable by `source: kong-ai-proxy-advanced` and `agent_role` (the persona)
- Adversarial prompts in A10 will surface as flagged turns (LLM Evasion /
  System Prompt Leak / Misuse depending on tenant controls)
- The Supervisor (A9) shows `delegate_to_specialist` as a tool call,
  demonstrating multi-agent visualization
- ParallelTools (A12) shows multiple tool_calls in a single assistant turn
