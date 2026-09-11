# Coding-agent plugins — install notes

This page is the operational companion to the [README](../README.md#coding-agents). It assumes you already run Kong and want to attach **one** of:

- `straiker-coding-agent-streaming` — interactive developers
- `straiker-coding-agent-buffered` — CI / unattended agents

Never attach both to the same route. Do not attach the chat plugin `straiker` to these routes.

## Body buffer

```
nginx_http_client_body_buffer_size = 32m
nginx_http_client_max_body_size = 64m
```

Or `KONG_NGINX_HTTP_CLIENT_BODY_BUFFER_SIZE=32m`. Restart Kong. At the 8 KB default, `get_raw_body()` returns nil and the plugin stamps `x-straiker-verdict: fail-open-no-body` while proxying uninspected. This is node-level; if you cannot set it, stop.

## `api_key` and vaults

`api_key` is encrypted and referenceable.

**Environment vault** needs two settings:

```sh
export STRAIKER_API_KEY=…
export KONG_NGINX_MAIN_ENV=STRAIKER_API_KEY
```

```yaml
api_key: "{vault://env/straiker-api-key}"   # env name, lowercased, - for _
```

Without `KONG_NGINX_MAIN_ENV`, nginx wipes the worker environment, the reference resolves to nil, and the plugin fails open (`fail-open-no-key`) with no error. Kong renders `nginx_main_env` as a **single** `env` directive — more than one secret needs AWS / GCP / Azure / HashiCorp / Konnect Config Store.

decK `${{ env "DECK_STRAIKER_API_KEY" }}` writes the literal at apply time. Fine for a trial. decK aborts on an unset `DECK_` variable but substitutes an empty string for set-but-empty.

## Konnect hybrid schemas

POST each coding-agent `schema.lua` once. Update with PUT on the plugin name (`POST` fails with a unique-name constraint once the schema exists). A schema update does not reconcile to data planes until some other config change forces a payload — touch an entity and verify.

## Dedicated Cloud Gateways

Dedicated Cloud Gateways now stream the whole plugin from the control plane (Gateway 3.15+), so there is nothing to install on a data plane — you POST `handler.lua` and `schema.lua` together to `core-entities/custom-plugins`. See [Install → Konnect Dedicated Cloud Gateways](../README.md#konnect-dedicated-cloud-gateways).

Three consequences for these plugins specifically.

**A streamed plugin is only those two files.** Nothing else is on the data plane's Lua path, so a handler that requires a sibling module dies at load with `handler load failure … module 'kong.plugins.straiker.…' not found`, and the whole declarative config is rejected — not just that plugin. Both coding-agent handlers are self-contained; `tools/check-shared-blocks.sh` keeps the duplicated regions in step.

**`require` is gated by `KONG_UNTRUSTED_LUA`.** This is the setting to get right, and it is settable per gateway at creation time. Kong's default is `strict`, which allows no network module, so the handler fails at load with `require("resty.http") not allowed within sandbox` and takes the config down with it. `lax` allowlists `resty.http` and `cjson.safe`; `on` is unrestricted. Both work. Do not confuse this failure with the module-not-found above: that one lists every path Lua searched, this one never reaches the search.

**Timers are documented as unavailable, but are not actually blocked.** `straiker-coding-agent-streaming` relays the model's response from `ngx.timer.at`, because `log_by_lua` forbids cosockets and `resty.http` needs them — there is no alternative once the bytes have shipped. Kong's sandbox nevertheless hands a plugin the entire `ngx` global in every mode (`kong/tools/sandbox/configuration.lua`, commented "including timers, :-("), so read the restriction as a request not to rather than a wall: a timer outlives the request holding a closure over plugin config, which is a hazard when the control plane hot-swaps streamed code.

If a spawn is ever refused, the plugin logs `relay timer spawn failed` and continues — requests are still inspected and still blocked. The loss is smaller than it looks, because the client replays the assistant message (including `tool_use` blocks) in the next request, which `access` already forwards; what is actually missed is the final turn of a session and the SSE-only metadata. To drop the relay deliberately set `relay_response: false`, or use `straiker-coding-agent-buffered`, which scores the response inline in the `response` phase and needs no timer.

Konnect **Serverless** gateways still refuse custom plugins outright. Inline `pre-function` is not a workaround there: under `strict` it cannot require `resty.http`, so it cannot call Straiker Defend.

## Identity

Claude Code sends no user identity. If the route already has `key-auth`, JWT, mTLS, or OIDC, the plugin forwards the Kong consumer as `x-straiker-user`.

Without an auth plugin, turns are **not** unattributed — they are attributed to whatever the client claims. `resolve_user()` falls back to the request's own `x-consumer-username` header, which nothing on an unauthenticated route sets but the caller, so `curl -H 'x-consumer-username: someone.else@example.com'` lands that string in Straiker as the acting user. Treat attribution on an unauthenticated route as a hint, never as evidence, and put an auth plugin on any route where it needs to hold.

Do **not** put a per-developer key in `x-api-key` — Claude subscription users send `Authorization: Bearer` and no `x-api-key`. Use a dedicated header (for example `apikey`) and `hide_credentials: true` so that key is not forwarded upstream.

If Kong injects the Anthropic platform key, `request-transformer` should `remove: authorization` so a subscription bearer is not preferred over `x-api-key`.

## Path and providers

Only `POST` paths ending in `/v1/messages` are scored. Health checks and `/v1/messages/count_tokens` are skipped on purpose.

Bedrock: the client body still reaches the plugin, but the model is in the URL — send `x-straiker-model` if you want it recorded.

`ai-proxy` + **buffered** never enforces: AI Proxy clears `ctx.buffered_proxying` whenever the client streams, and coding agents always stream, so `tool_use` blocking silently stops with no error and an allow verdict. Use the streaming plugin, or drop `ai-proxy` from that route and inject the upstream credential with `request-transformer`.

Declare `protocols: [http, https]` on the route if Kong would otherwise infer HTTPS from the service URL and answer plain HTTP with `426`. Buffered upstreams need a high service `read_timeout` (inter-read, not total).

## Fail-open headers

Default `fail_open: true`. Alert on these; they look like a healthy allow.

| `x-straiker-verdict` | Meaning |
| --- | --- |
| `allow` / `deny` | Working |
| `fail-open-no-body` | Body exceeded the nginx buffer |
| `fail-open-no-key` | Empty key or unresolved vault |
| `fail-open-http-401` | Straiker Defend rejected the key |
| `fail-open-unreachable` | DNS / TLS / timeout / firewall |
| `fail-open-http-*` | Other Detect status |
| `fail-open-parse` | Detect body was not JSON we could read |
| *(no header)* | Plugin not on this route, or path is not `/v1/messages` |

Response-phase tags use `x-straiker-response-verdict`. Kong logs a `straiker` object on the log serializer (`verdict`, `call_kind`, `top_score`, …).

`fail_open: false` returns HTTP 503 on Detect failure. Claude Code may retry 503.

## Deny UX

Blocks are HTTP 200, Anthropic `stop_reason: end_turn`, `x-straiker-verdict: deny`. Do not change this to 403 or 5xx.

## Memory

Both plugins hold a whole response in memory, so budget roughly 1 MB per concurrent request either way.

- **Buffered** — Kong holds the upstream response until Straiker Defend scores it. Alert on `an upstream response is buffered to a temporary file`; disk spill blocks the event loop.
- **Streaming** — the response is accumulated for the async relay. `relay_response: false` skips the buffer entirely, at the cost of losing the model's answer on the last turn of every session. Sidecar turns are never buffered.

`max_response_bytes` (8 MiB default) caps both. Past the cap, response telemetry is dropped for that turn and logged; proxied traffic is unaffected.

## Verify

See the README coding-agent curl. End-to-end: point Claude Code at the route and ask it to `pip install --dry-run 1337test` with malicious-package policy in block mode. Obvious exfiltration prompts are poor tests — the model often refuses them before Straiker Defend sees them.
