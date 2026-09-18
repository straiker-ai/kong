# Coding agents — operational notes

The operational companion to the [README](../README.md). It assumes you already run Kong and are attaching `straiker` to a route carrying Anthropic Messages traffic from Claude Code or a similar client.

Everything here applies to the single `straiker` plugin. Delivery mode is the `STRAIKER_KONG_MODE` environment variable — see [Delivery mode](../README.md#delivery-mode).

## Body buffer

```
nginx_http_client_body_buffer_size = 32m
nginx_http_client_max_body_size = 64m
```

Or `KONG_NGINX_HTTP_CLIENT_BODY_BUFFER_SIZE=32m`, then restart. At the 8 KB default `get_raw_body()` returns nil and traffic proxies uninspected. This is node-level; if you cannot set it, request-body inspection is not possible and you should stop here.

## Keys and vaults

`api_key`, `detect_url`, `upstream_api_key` and `user_ref` are all vault-referenceable. Anything a `.env` value reaches must be, or Kong passes the reference through verbatim and the literal `{vault://…}` string is used as the value.

**The environment vault needs two settings, not one:**

```sh
export STRAIKER_API_KEY=…
export KONG_NGINX_MAIN_ENV=STRAIKER_API_KEY
```

```yaml
api_key: "{vault://env/straiker-api-key}"   # env name, lowercased, - for _
```

Without `KONG_NGINX_MAIN_ENV`, nginx wipes the worker environment and the reference resolves to nothing.

Kong renders `nginx_main_env` as a single `env` directive, so several names are chained by closing and reopening it:

```sh
export KONG_NGINX_MAIN_ENV="STRAIKER_API_KEY; env ANTHROPIC_API_KEY"
```

That works, but it is a templating trick rather than a supported list. For anything beyond a couple of values, use a real vault backend — AWS, GCP, Azure, HashiCorp, or the Konnect Config Store.

decK's `${{ env "DECK_…" }}` writes the literal value at apply time, which is fine for a trial but puts the secret in whatever decK applied from. decK aborts on an unset `DECK_` variable but substitutes an empty string for one that is set but empty.

## Upstream credential

Let the gateway hold the model credential and set `upstream_api_key`; the plugin injects it and clears the client's `authorization`, so developers never hold a platform key.

Do **not** try to do this with `request-transformer`. Its header arrays are not vault-referenceable (`config.add.headers  type=array  referenceable=False`), so a `{vault://…}` reference reaches the provider verbatim and fails as a 401 that reads exactly like a wrong key.

The alternative is pass-through: set no `upstream_api_key` and let each developer's own credential flow to the provider. That gives you per-developer billing and attribution upstream, at the cost of every developer holding a key.

## Attribution

The plugin reads the **Kong Consumer** first. Its priority (760) sits below the auth plugins (`key-auth` 1250, `jwt` 1450), so on an authenticated route the consumer is already resolved and each turn names the actual caller. That is how you get per-developer attribution from a shared gateway: put an auth plugin on the route and give each developer a credential.

`user_ref` is the **fallback**, reached only when no consumer resolved. On a route with no auth it is the honest answer — it names the integration, not a person.

There is deliberately no `x-consumer-username` header fallback. Reading that header when no consumer resolves would mean that on an unauthenticated route the caller chooses the name recorded against their own traffic; `curl -H 'x-consumer-username: someone.else@example.com'` is the whole attack. Attribution on an unauthenticated route is a label, never evidence.

Do **not** put a per-developer key in `x-api-key` — Claude subscription users send `Authorization: Bearer` and no `x-api-key`. Use a dedicated header such as `apikey` with `hide_credentials: true`, so the key identifies the developer to Kong without being forwarded upstream.

Sessions are different: `x-claude-code-session-id` is used when the client sends it, and otherwise `session_from_body` derives a stable digest from the system preamble plus the first user message. Both are stable across the turns of one conversation, because a transcript grows at the end.

## Route scoping

The plugin scores any POST on a route it is attached to; it does not inspect the path. Two consequences:

- A plain Kong path is a **prefix** match, so `paths: ["/v1/messages"]` also captures `/v1/messages/count_tokens`. Use `~/v1/messages$`.
- Give `count_tokens` its own route with `score_request: false` and `score_response: false`. Claude Code fires it constantly, it replays the whole conversation, and it carries no system prompt — so scoring it double-counts every turn and classifies the traffic on structure alone.

Declare `protocols: ["http", "https"]` on every route. Without it Kong infers HTTPS-only from an `https://` service URL and answers plain HTTP with `426 Upgrade Required` at routing, before any plugin phase runs — no verdict header, nothing in the log.

Buffered upstreams need a high service `read_timeout`. It is an inter-read timeout, not a total one, but the answer is only delivered once generation finishes.

The Claude desktop app probes `GET /v1/models` and refuses a gateway that 404s it. Route it, and attach the plugin with both scoring flags off so the credential is still injected.

## Konnect

**Hybrid.** POST `schema.lua` once; update with PUT on the plugin name, since POST fails a unique-name constraint once it exists. A schema update does not reconcile to data planes until some other config change forces a payload — touch an entity and verify.

**Dedicated Cloud Gateways.** The whole plugin is streamed from the control plane (Gateway 3.15+): POST `handler.lua` and `schema.lua` together. Three things to know.

A streamed plugin is only those two files. A handler requiring a sibling module dies at load and takes the **whole declarative config** with it, not just itself. `tools/check-plugin-layout.sh` is what keeps the tree streamable.

`require` is gated by `KONG_UNTRUSTED_LUA`, settable per gateway at creation time. Kong's default `strict` allows no network module, so the handler fails with `require("resty.http") not allowed within sandbox`. Use `lax`, which allowlists exactly `resty.http` and `cjson.safe`; `on` also works but removes the sandbox for every custom plugin on that gateway, including ones added later by someone else. Do not confuse this with a module-not-found error — that one lists every path Lua searched, this never reaches the search.

Timers are documented as unavailable but are not actually blocked. In `streaming` mode the plugin relays the answer from `ngx.timer.at`, because `log_by_lua` forbids cosockets and `resty.http` needs them. Kong's sandbox hands a plugin the entire `ngx` global in every mode, so read the restriction as a request rather than a wall — a timer outlives the request while holding a closure over plugin config, which is a hazard when the control plane hot-swaps streamed code. `buffered` mode needs no timer at all.

Konnect **Serverless** gateways refuse custom plugins outright. Inline `pre-function` is not a workaround: under `strict` it cannot require `resty.http`, so it cannot call Straiker.

Streamed plugins have no versioning. To change one, upload under a new name, move the plugin instances, then delete the old one.

## Memory and disk

Both modes hold a whole response in memory, so budget roughly 1 MB per concurrent request. `max_body_bytes` (10 MiB default) caps it; past the cap the turn is not scored and the fact is logged, while proxied traffic is unaffected.

In `buffered` mode Kong also spills the upstream response to an nginx temp file once it exceeds the proxy buffers, which happens routinely with real coding-agent responses. Two implications: disk spill blocks the event loop, so alert on `an upstream response is buffered to a temporary file`; and model output is written to the data plane's filesystem, which matters if your traffic is regulated. Size `proxy_max_temp_file_size` deliberately rather than inheriting the default.

## Verdicts to alert on

| `x-straiker-verdict` | Meaning |
| --- | --- |
| `allow` | Scored, nothing fired |
| `detect` | A control fired while the tenant is in detect mode. Not a block, by design |
| `block` | Enforced; the answer was replaced |
| `degraded` | Straiker unreachable or errored, `fail_closed` false — traffic passed **uninspected** |
| `unknown` | Straiker answered in a shape the plugin could not read — also **uninspected** |
| *(no header)* | The plugin is not on this route, or the request never reached it |

`degraded` and `unknown` are the ones that matter: both look like a healthy 200 while the control is not running. `fail_closed: true` turns a `degraded` into a rejection instead, which is the right choice for unattended CI and the wrong one for interactive developers.

A block is HTTP **200** with `stop_reason: end_turn`. Do not change this to 403 or 5xx: Claude Code reads 403 as an auth failure and prompts for re-login, and retries 5xx.

## Verifying

Point Claude Code at the route and give it a task that trips a policy you have in block mode — a package install against malicious-package policy works well.

Obvious exfiltration prompts are poor tests. The model usually refuses them before Straiker ever sees a tool call, so you learn nothing about enforcement. For a deterministic check of the enforcement path itself, point `detect_url` at a stub that returns a deny and confirm the `tool_use` does not reach the client in `buffered` mode.
