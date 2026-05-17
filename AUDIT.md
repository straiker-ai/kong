# v0.4.0 Code Audit

Internal audit of `kong/plugins/straiker/handler.lua` and `schema.lua` against
security, correctness, performance, and code-quality criteria. Done as part
of preparing the v0.4.0 release for general availability.

## Summary

- **Security:** PASS — no high or medium-severity findings
- **Correctness:** PASS — all three critical fixes from the v0.4.0 integration testing are present and verified
- **Performance:** PASS — one medium-severity finding (O(n²) body_filter accumulation) addressed in this audit pass
- **Code quality:** PASS — short functions, explanatory comments on non-obvious code, no dead code

## Security

| Item | Result |
|---|---|
| API key handled as encrypted, referenceable field in schema | ✅ |
| TLS verification enabled on outbound Straiker calls (`ssl_verify = true`) | ✅ |
| API key never appears in `NOTICE`/`ERR` logs | ✅ (only in payload encoded for outbound POST) |
| Payload logged at `DEBUG` only — operators must not enable DEBUG in production | ⚠ Advisory: documented in README |
| `pcall` around external decoders: `cjson.decode`, `kong_gzip.inflate_gzip`, `kong.client.get_consumer` | ✅ |
| No `eval`, `loadstring`, or `os.execute` paths | ✅ |
| `conf.detect_url` and `conf.api_key` are operator-controlled (not user input) | ✅ |
| Body tempfile path comes from `ngx.req.get_body_file()` (Kong-supplied) — no path traversal | ✅ |
| Connection keepalive configured (`keepalive_timeout = 60000`, `keepalive_pool = 10`) | ✅ |

## Correctness — v0.4.0 critical fixes verified

The three fixes that were required to make v0.4.0 work behind AI Proxy Advanced:

| Fix | Location | Verified |
|---|---|---|
| `cjson.null` sentinel handling on `tool_calls` and `content` | `body_filter`, single-shot JSON path | ✅ tests cover `tool_calls: null` final iterations |
| `client_body_buffer_size` tempfile fallback on large agent-loop bodies | `access` phase | ✅ tests cover messages[] > 8 KiB |
| Gzip inflation of upstream response when `Content-Encoding: gzip` | `header_filter` + `body_filter` | ✅ tests cover openai-python traffic behind ai-proxy-advanced |

Other correctness checks:

| Item | Result |
|---|---|
| Mode `pre_call` / `post_call` / `both` paths all covered correctly | ✅ |
| Iteration-aware agentic dedupe (skip pre-call on continuation iterations, skip post-call on intermediate tool-call iterations) | ✅ |
| Phantom-turn block flag (`kong.ctx.plugin.blocked`) prevents spurious post-call after pre-call HTTP 403 | ✅ |
| `detect_url` correctly appends `?agentic` or `&agentic` based on existing query | ✅ |
| `transform_tool_calls` reshapes OpenAI `{id, type, function:{name, arguments}}` → Straiker flat `{id, name, input}` | ✅ |
| SSE accumulator preserves chunked `delta.content` and incremental `tool_calls` indices | ✅ |
| Schema fields all referenced by handler, no orphan or missing fields | ✅ |
| `fail_open` honored on both Straiker-unreachable and Straiker-non-200 paths | ✅ |

## Performance — findings and fixes applied in this pass

| Finding | Severity | Fix |
|---|---|---|
| `body_filter` accumulated chunks via repeated string concat, O(n²) on large streams | MEDIUM | Switched to `parts = {}` table + `table.concat(parts)` at EOF. O(n). |
| `parse_sse_buffer` walked `tool_call_acc` via `while tool_call_acc[i]` (assumes contiguous indices starting at 1; OpenAI emits contiguous indices but starting at 0) | LOW | Switched to collecting all indices with `pairs`, sorting, then iterating. Defensive against gaps and non-zero start. |
| Per-request `httpc` object created and discarded; `lua-resty-http` reuses pooled connections via keepalive | n/a | Already pooled — no action needed. |
| `kong.ctx.plugin.body_parts` table freed after `table.concat` at EOF | n/a | Set to nil to release earlier. |

## Code quality

- Function length: all handler functions < 50 lines except `body_filter` (~55 lines including SSE/JSON branch) and `parse_sse_buffer` (~50 lines). Both have a single purpose.
- Comments explain WHY for non-obvious behavior: PRIORITY rationale, body-tempfile fallback, gzip inflation, `cjson.null` sentinel, iteration-aware dedupe, phantom-turn flag.
- No dead code. `kong.ctx.plugin.streamed_tool_calls` is set but unused — left in place as a hook for future provider-native parsing; can remove if not adopted within the next release.
- Naming is descriptive. No abbreviated identifiers.
- Error paths use `kong.log.err` with context (turn id where applicable).

## Doc–code consistency

| Claim in docs | Handler / schema | Match |
|---|---|---|
| `mode` is `pre_call`, `post_call`, or `both` | `schema.lua` `one_of = { "pre_call", "post_call", "both" }` | ✅ |
| `agentic` boolean, default false | `schema.lua` `default = false` | ✅ |
| `ai_proxy_advanced_compat` boolean, default false | `schema.lua` `default = false` | ✅ |
| `threshold` default `0.5`, between 0 and 1 | `schema.lua` `default = 0.5, between = { 0, 1 }` | ✅ |
| `timeout` default 5000 | `schema.lua` `default = 5000` | ✅ |
| `fail_open` default false | `schema.lua` `default = false` | ✅ |
| `api_key` encrypted/referenceable | `schema.lua` `encrypted = true, referenceable = true` | ✅ |
| PRIORITY 760 (after ai-proxy-advanced at 770) | `handler.lua` `PRIORITY = 760` | ✅ |
| VERSION 0.4.0 | `handler.lua` `VERSION = "0.4.0"` | ✅ |
| Rock filename `kong-plugin-straiker-0.4.0-1.all.rock` | rockspec `version = "0.4.0-1"` | ✅ |

## Open / advisory items

- **DEBUG logging of full payload** — `call_straiker` logs the outbound payload at `DEBUG`. Acceptable for development; operators should keep Kong's `log_level` at `notice` or higher in production. README mentions this.
- **`streamed_tool_calls` unused** — preserved as a forward-compatibility hook; remove in a follow-up if not adopted.
- **No automated tests in CI** — current verification is via the agent harnesses in `scripts/`. Adding `busted`-style unit tests for `transform_tool_calls`, `parse_sse_buffer`, and `last_user_prompt` would shorten the regression cycle. Tracked as a follow-up.
