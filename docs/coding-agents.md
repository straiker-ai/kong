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

Cloud Gateways refuse custom plugins (`400 custom plugins are not supported in Cloud Gateways`). Inline `pre-function` cannot call Straiker Defend (`resty.http` is sandboxed).

## Identity

Claude Code sends no user identity. If the route already has `key-auth`, JWT, mTLS, or OIDC, the plugin forwards the Kong consumer as `x-straiker-user`. Otherwise turns are unattributed.

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
