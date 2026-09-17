-- straiker: one Kong plugin, both enforcement shapes, v3 Detect.
--
-- TWO FILES, AND THAT IS A HARD LIMIT. Konnect Dedicated Cloud Gateways run custom
-- plugins as streaming plugins, which ship EXACTLY handler.lua and schema.lua.
-- Nothing else reaches the data plane's Lua path, so a sibling `require` resolves
-- against nothing, and ONE plugin that fails to load rejects the whole declarative
-- config rather than just itself. Everything is therefore inlined here; resist the
-- urge to factor shared helpers out into a third file.
--
-- WHAT IT IS. A transport. It forwards bytes to Straiker Detect and does what it is
-- told. Every scoring decision is made by the service, not here. Keep it that way:
-- logic added in this file duplicates the service and drifts away from it.
--
-- THE ONE KNOB, AND WHY IT IS AN ENV VAR RATHER THAN A CONFIG FIELD.
--
-- Kong refuses to load a plugin that implements both `response` and `body_filter`:
--
--   "Plugin X can't be loaded because it implements both `response` and
--    `header_filter` or `body_filter` methods."
--
-- The phases are mutually exclusive because `response` forces Kong to buffer the
-- whole upstream body, which is precisely what streaming must not do.
--
-- A config field cannot bridge that: Kong inspects the handler table at load time,
-- so the methods have to be statically present or absent. `STRAIKER_KONG_MODE` is
-- read once here, at module load, and decides which shape this table has for the
-- life of the worker. One plugin, two files, both enforcement shapes, chosen at boot.
--
--   buffered (default)  `access` + `response`. Kong holds the answer, so a flagged
--                       one can still be withheld. The client gets the reply in one
--                       piece: token streaming is gone for every route using it.
--   streaming           `access` + `body_filter` + `log`. Tokens flow through
--                       untouched and the post-call verdict is ADVISORY by
--                       construction, since the bytes are already with the client
--                       when it lands. It logs that plainly rather than pretending.
--
-- Both shapes enforce on the PROMPT identically. Only the answer differs.
-- Switching modes is a restart, which is what a process-level choice costs.

local cjson = require "cjson.safe"
local http  = require "resty.http"

-- ⚠️ **760 is deliberate, and it is below ai-proxy (770) on purpose.**
--
-- ai-proxy switches Kong's response buffering off whenever the client streams,
-- and coding agents always stream. Kong's plugins iterator sets
-- `ctx.buffered_proxying` when it COLLECTS a plugin declaring `response`, and
-- collection is interleaved with access execution in descending priority order.
-- So the last plugin to touch the flag wins:
--
--   at 1000  we set it -> ai-proxy clears it -> nothing restores it.
--            `response` never runs. The answer is never scored, the client still
--            gets 200 with an `allow` verdict, and nothing says enforcement
--            stopped. Measured: request-phase call only, no `response-sync`.
--   at 760   ai-proxy clears it -> we are collected after and it is set again.
--            `response` runs. Measured: request + `response-sync`, and the
--            captured body is still the client's own Anthropic request.
--
-- Still far below Kong auth (key-auth 1250, jwt 1450), so the Consumer is
-- resolved before `access` and attribution is unaffected.
--
-- The cost is ordering, on BOTH halves of the request:
--
--   request   we now sit after request-transformer (801) and after any ai-proxy
--             rewrite, so `get_raw_body()` is whatever ai-proxy produced rather
--             than guaranteed to be the client's own.
--   response  in `streaming` mode our `body_filter` now runs after ai-proxy's
--             SSE normalizer, so the relayed bytes are its output rather than
--             the raw upstream stream.
--
-- On an Anthropic-to-Anthropic route -- the documented coding-agent topology --
-- both rewrites are pass-throughs and the bytes are unchanged; verified against
-- a captured request and a captured relay. A provider where ai-proxy genuinely
-- reshapes the traffic would hand us its translation on both halves. If the raw
-- client bytes must be guaranteed, keep ai-proxy off that route.
local Straiker = { PRIORITY = 760, VERSION = "0.12.0" }

-- Read ONCE, at module load. See the header for why this cannot be config.
local MODE = os.getenv("STRAIKER_KONG_MODE")
if MODE ~= "streaming" then MODE = "buffered" end

local VERDICT_HEADER = "x-straiker-verdict"
local STOP_REASON    = "end_turn"

-- ⚠️ **`straiker_phase` is not a label, it is the enforceability switch, and only
-- this exact spelling turns it on.** Straiker treats `"response-sync"` as an answer
-- the gateway is still holding -- one whose verdict can therefore still stop the
-- tool calls inside it. Any other value means the answer has already left, so it is
-- recorded but not acted on.
--
-- Sending the wrong value is worse than a no-op. A tool call reported as already
-- gone is de-duplicated against the copy that arrives in the next request, so the
-- one chance to adjudicate it is consumed by the report. Blocks silently become
-- observations, and buffered mode looks like it is enforcing when it is not.
--
-- The streaming relay genuinely is after the fact: the bytes reached the client
-- before the verdict existed. It keeps `"response"` because that is true of it.
local PHASE_BUFFERED  = "response-sync"
local PHASE_STREAMING = "response"

-- cjson encodes an empty Lua table as {}; Anthropic sends "content": [].
local EMPTY_ARRAY = cjson.empty_array
                    or (cjson.array_mt and setmetatable({}, cjson.array_mt))
                    or {}

-- No name prefix: Kong already stamps `[straiker]` on every line, and adding
-- our own produced `[straiker] [straiker] ...` in the first real run.
local function log_warn(msg, ...)
  kong.log.warn(string.format(msg, ...))
end


-- --------------------------------------------------------------------------
-- Denial, synthesized as an assistant turn.
--
-- 200 and `end_turn`, never an HTTP error. Measured against claude-cli 2.1.221:
--
--   403 + error body  -> "Please run /login". Claude Code maps 403 onto an auth
--                        failure, so a policy block reads as broken credentials and
--                        the developer re-authenticates instead of reading the reason.
--   200 + "refusal"   -> renders, then kills the session and blames Anthropic's
--                        Acceptable Use Policy. A working context lost, wrong vendor
--                        blamed.
--   200 + "end_turn"  -> policy text as an ordinary assistant reply. The session
--                        survives and the next turn works.
--
-- Retries are the other reason: Claude Code's budget is 10, and it retries
-- 408/409/429/5xx/529, the last indefinitely.
-- --------------------------------------------------------------------------

local function sse(event, data)
  return "event: " .. event .. "\ndata: " .. cjson.encode(data) .. "\n\n"
end

local function deny(reason, model, streaming)
  local headers = { [VERDICT_HEADER] = "block" }
  local msg_id = "msg_straiker_" .. tostring(ngx.now()):gsub("%.", "")

  if not streaming then
    headers["Content-Type"] = "application/json"
    return kong.response.exit(200, {
      id = msg_id, type = "message", role = "assistant", model = model,
      content = { { type = "text", text = reason } },
      stop_reason = STOP_REASON, stop_sequence = cjson.null,
      usage = { input_tokens = 0, output_tokens = 0 },
    }, headers)
  end

  -- A JSON client handed an event stream sees a parse error instead of the policy
  -- text, so the shape has to follow what the client asked for, not what we prefer.
  headers["Content-Type"]  = "text/event-stream"
  headers["Cache-Control"] = "no-cache"
  return kong.response.exit(200, table.concat({
    sse("message_start", { type = "message_start", message = {
      id = msg_id, type = "message", role = "assistant", model = model,
      content = EMPTY_ARRAY, stop_reason = cjson.null, stop_sequence = cjson.null,
      usage = { input_tokens = 0, output_tokens = 0 } } }),
    sse("content_block_start", { type = "content_block_start", index = 0,
      content_block = { type = "text", text = "" } }),
    sse("content_block_delta", { type = "content_block_delta", index = 0,
      delta = { type = "text_delta", text = reason } }),
    sse("content_block_stop", { type = "content_block_stop", index = 0 }),
    sse("message_delta", { type = "message_delta",
      delta = { stop_reason = STOP_REASON, stop_sequence = cjson.null },
      usage = { output_tokens = 0 } }),
    sse("message_stop", { type = "message_stop" }),
  }), headers)
end


-- --------------------------------------------------------------------------
-- Talking to v3 Detect.
--
-- AUTH IS ONE HEADER: a bearer token, and nothing else. `/api/v3/detect` is
-- authenticated at Straiker's edge, which resolves the key to the integration you
-- configured and derives the traffic's identity from it. That is why the plugin
-- sends no ingress or tool headers -- how this traffic is attributed is a property
-- of the KEY, set once when the integration is created, not of anything sent here.
-- --------------------------------------------------------------------------

-- ⚠️ **`session` is PASSED IN rather than read here, and that is the whole reason
-- the streaming relay works at all.**
--
-- This used to call `kong.request.get_header("x-claude-code-session-id")` itself.
-- That is fine in `access` and in `response`, and fatal in the streaming relay:
-- that one runs inside `ngx.timer.at`, a timer gets a FRESH `ngx.ctx`, and every
-- PDK request accessor checks `ngx.ctx.KONG_PHASE` first. So the relay died on
-- every single streamed response with
--
--   failed to run timer ... no phase in ngx.ctx.KONG_PHASE
--
-- logged at error level under `[timer-ng]` rather than under the plugin, and with
-- nothing reaching Detect. Streaming mode was scoring the prompt and silently
-- nothing else. Capture in `access`, where the phase is real, and carry the value.
local function hint_headers(conf, session)
  local headers = {
    ["Content-Type"]  = "application/json",
    ["Authorization"] = "Bearer " .. conf.api_key,
  }
  if conf.client      then headers["x-s6r-client"] = conf.client end
  if conf.agent_ref   then headers["x-s6r-agent"]  = conf.agent_ref end
  if conf.format_hint then headers["x-s6r-format"] = conf.format_hint end

  -- Forwarded when the client sends it: it is how a coding session groups, and the
  -- header wins over the body's `metadata.user_id`.
  if session then headers["x-claude-code-session-id"] = session end
  return headers
end

-- The identity a relayed body cannot carry, added to the DETECT payload only.
--
-- ⚠️ **Neither of these travels upstream.** The model sees the client's bytes
-- unchanged; only the copy posted to Straiker is enriched. Mutating the forwarded
-- body would change what the model is asked, which a security transport must not do.
--
-- Adding these does not change how the payload is classified: neither field is a
-- format discriminator, so a Messages body enriched this way is still read as a
-- Messages body. Verified rather than assumed.
-- Who the turn is about.
--
-- The Kong Consumer first. This plugin's priority (760) sits below the auth plugins
-- (key-auth 1250, jwt 1450), so on an authenticated route the consumer is already
-- resolved by the time `access` runs and it names the actual caller rather than the
-- route. `user_ref` is the static per-route fallback for routes with no auth.
--
-- ⚠️ **There is deliberately no `x-consumer-username` fallback.** Reading that header
-- when no consumer resolves means that on an UNAUTHENTICATED route the caller picks
-- the name recorded against their own traffic -- `curl -H 'x-consumer-username: …'`
-- is the whole attack. An unauthenticated route has no identity to report, so the
-- honest answer there is `user_ref` or nothing.
--
-- Safe in every phase this is reached from: `access` for the prompt, `response` or
-- `log` for the answer. The streaming relay builds its payload in `log`, before the
-- timer, precisely because `kong.client` does not exist inside one.
local function acting_user(conf)
  local get_consumer = kong.client and kong.client.get_consumer
  local consumer = get_consumer and get_consumer()
  if consumer and consumer.username and consumer.username ~= "" then
    return consumer.username
  end
  return conf.user_ref
end

local function with_identity(conf, ctx, payload)
  if ctx.straiker_session then payload.session_id = ctx.straiker_session end
  local user = acting_user(conf)
  if user then
    -- The one place Straiker looks for a user on a relayed request: v3 has no user
    -- header at all, so the body is the only place a caller can name one. Without it
    -- turns are attributed to nobody.
    payload.original = { processed = { Meta = { user = user } } }
  end
  return payload
end

-- A session id for a conversation that states none.
--
-- The header first: Claude Code sends `x-claude-code-session-id` and it is the
-- client's own id, so it survives load balancing. Falling back to a digest keeps
-- surfaces that send no header -- the desktop app among them -- from being given a
-- fresh, synthetic session on every request, which groups nothing.
local function conversation_id(conf, req)
  local supplied = kong.request.get_header("x-claude-code-session-id")
  if supplied and supplied ~= "" then return supplied end
  if not conf.session_from_body then return nil end

  -- The client's own id, when it states one. Only reachable on the REQUEST half:
  -- on the response envelope the body is nested under `request`, and the session is
  -- read from the top level only -- so lifting it here is what keeps both halves of
  -- one turn under the same session.
  if type(req.session_id) == "string" and req.session_id ~= "" then
    return req.session_id
  end

  local system = req.system
  if type(system) == "table" then system = cjson.encode(system) end
  -- `instructions` is the OpenAI Responses spelling of a preamble.
  if system == nil and type(req.instructions) == "string" then
    system = req.instructions
  end

  -- ⚠️ **Three spellings of "the first thing the user said", because three request
  -- contracts reach this plugin and seeding off only `messages` silently returned
  -- nil for the other two.** A chat body (`{prompt}`) and an OpenAI Responses body
  -- (`input`) both collapsed the seed to "\0", so every one of their turns was given
  -- a fresh synthetic session and nothing grouped.
  local first = ""
  local msgs = req.messages or req.input
  if type(msgs) == "table" and msgs[1] then
    local c = msgs[1].content
    if type(c) == "string" then first = c
    elseif type(c) == "table" and c[1] then first = c[1].text or "" end
  elseif type(req.prompt) == "string" then
    first = req.prompt
  end

  local seed = tostring(system or "") .. "\0" .. tostring(first)
  if seed == "\0" then return nil end
  return "kong-" .. ngx.md5(seed)
end

-- Returns the decoded verdict, or nil plus an error string.
-- `session` is the client's `x-claude-code-session-id`, captured in `access`; see
-- `hint_headers` for why it cannot be read here.
local function score(conf, payload, session)
  local body = cjson.encode(payload)
  if not body then return nil, "could not encode the payload" end
  if #body > conf.max_body_bytes then
    return nil, "payload above max_body_bytes (" .. #body .. ")"
  end

  local httpc = http.new()
  httpc:set_timeout(conf.timeout_ms)

  local headers = hint_headers(conf, session)
  headers["Content-Length"] = #body

  local res, err = httpc:request_uri(conf.detect_url, {
    method = "POST", body = body, headers = headers,
  })
  if not res then return nil, err or "no response" end
  if res.status ~= 200 then
    return nil, "detect returned " .. tostring(res.status)
  end

  local verdict = cjson.decode(res.body)
  if type(verdict) ~= "table" then
    return nil, "detect returned a non-object body"
  end
  return verdict
end

-- ⚠️ **`cjson.null` is userdata, and userdata is TRUTHY in Lua**, so a plain
-- `a or b` chain returns the null instead of falling through to the fallback.
-- `block_message` arrives as JSON null whenever no custom message is configured,
-- so this guard is the normal case rather than an edge one.
--
-- Without it a genuine block renders as `content:[{"type":"text","text":null}]`:
-- correctly blocked, `stop_reason: end_turn`, and completely silent. To the
-- developer that is the agent stopping for no stated reason, which is the worst
-- possible way to enforce a policy. Route every optional string from a verdict
-- through `present()`.
--
-- Defined above `decision_of` deliberately: a `local function` is only visible to
-- what follows it, so declaring this after its callers would silently bind them to
-- a nil global instead.
local function present(v)
  if v == nil or v == cjson.null or v == "" then return nil end
  return v
end

-- ⚠️ **The detect API answers in TWO envelopes and only one carries `action`.**
-- A turn on a gateway integration comes back as
-- `{hookSpecificOutput:{permissionDecision}, stopReason?}` with no top-level
-- `action` at all; other integrations get `{action, block_message, ...}`. Which
-- one you receive follows from the integration the API key resolves to, so a
-- single deployment can legitimately see either.
--
-- Reading only `action` made every gateway verdict nil: the header stamped
-- `unknown` and -- the failure that matters -- `blocked()` returned false on a
-- genuine deny, so the answer shipped anyway. Normalizing both shapes in one
-- place is what keeps that from being reintroduced.
local function decision_of(verdict)
  if not verdict then return nil end
  local hook = verdict.hookSpecificOutput
  if type(hook) == "table" and present(hook.permissionDecision) then
    return hook.permissionDecision
  end
  return present(verdict.action)
end

-- One place decides what a verdict means, so the two phases cannot drift.
--
-- The neutral v3 body answers `action` as allow / detect / block. `detect` is NOT a
-- block: it means a control fired while the tenant is in detect mode, and treating
-- it as one would enforce policy the tenant deliberately left off.
-- ⚠️ **Several vocabularies reach this function, and only one of them says "block".**
-- Anthropic inference-hook frames and the gateway envelope both answer allow /
-- **deny** instead. Testing only for `"block"` let a denial through as an allow,
-- which is the one failure direction that must never be silent.
local function blocked(verdict)
  local action = decision_of(verdict)
  return action == "block" or action == "deny"
end

local function block_text(verdict)
  local blocked_by = verdict.blocked_by
  if type(blocked_by) ~= "table" or #blocked_by == 0 then
    blocked_by = { "policy" }
  end
  -- ⚠️ **`stopReason`, never `permissionDecisionReason`.** On the gateway envelope
  -- those two are written for different readers: `stopReason` is the text meant for
  -- the developer, while `permissionDecisionReason` addresses the model and reads as
  -- an instruction when shown to a human.
  return present(verdict.block_message)
         or present(verdict.deny_reason)
         or present(verdict.stopReason)
         or "Blocked by Straiker policy ("
            .. table.concat(blocked_by, ", ") .. ")."
end

-- A degraded control must stay visible. Silence here is what makes an outage look
-- like a clean allow, which is the failure this whole artifact exists to catch.
local function degraded(conf, where, err, model, streaming)
  log_warn("%s scoring failed: %s", where, err or "unknown")
  if conf.fail_closed then
    return deny("Straiker is unreachable and this gateway is fail-closed.",
                model, streaming)
  end
  kong.response.set_header(VERDICT_HEADER, "degraded")
end


-- --------------------------------------------------------------------------
-- access: the prompt. Identical in both modes.
-- --------------------------------------------------------------------------

function Straiker:access(conf)
  local ctx = ngx.ctx

  -- ⚠️ **THE MOST EXPENSIVE BUG THIS PLUGIN CAN HAVE, and it is one line.**
  -- Buffering does NOT decompress. With `Accept-Encoding: gzip` -- which every SDK
  -- sends and curl does not unless asked, which is why hand testing misses it --
  -- `kong.service.response.get_raw_body()` returns gzip bytes, `cjson.decode` fails,
  -- and the post-call silently never happens. The build whose entire purpose is
  -- enforcing on responses stops doing so and looks perfectly healthy.
  kong.service.request.set_header("Accept-Encoding", "identity")

  -- The gateway holds the model credential, not the developer. Whatever the client
  -- used to authenticate to Kong is not an upstream credential, so it is replaced
  -- rather than supplemented.
  if conf.upstream_api_key then
    kong.service.request.set_header(conf.upstream_key_header, conf.upstream_api_key)
    if conf.upstream_key_header ~= "authorization" then
      kong.service.request.clear_header("authorization")
    end
  end

  -- Credential injection still happens above; this only skips the scoring.
  --
  -- ⚠️ **Both flags, not just `score_request`.** This guard used to be
  -- `score_request` alone and sat ABOVE the parse, so `score_request:false` with
  -- `score_response:true` returned before `ctx.straiker_request` was ever set --
  -- and the answer then shipped with no nested `request`, no `model` and no
  -- session. Straiker reads that nested half to learn what the traffic is, so the
  -- answer was classified against nothing. The request parse now happens whenever
  -- EITHER half is scored; only the scoring call itself is gated, further down.
  if not (conf.score_request or conf.score_response) then return end

  -- Nothing to score on a GET. The Claude desktop app probes `GET /v1/models` before
  -- it will accept a gateway at all, and without this that probe logged a warning
  -- about a missing body on every discovery call -- noise that would bury the real
  -- one below.
  if kong.request.get_method() ~= "POST" then return end

  -- ⚠️ **The argument is the difference between reading a big body and silently
  -- not inspecting it.** Bare `get_raw_body()` returns nil the moment nginx spills
  -- the body to a temp file -- which it does above `client_body_buffer_size`, only
  -- 8k by default. Coding-agent transcripts pass that routinely, so also raise
  -- `nginx_http_client_body_buffer_size` on the node.
  -- Given a limit, the PDK reads the spilled file itself, in 1 MB chunks with a
  -- yield between them. Bounded by the same `max_body_bytes` the scorer uses, so
  -- one setting governs both and we never read something we would then refuse.
  local raw, body_err = kong.request.get_raw_body(conf.max_body_bytes)
  if not raw or raw == "" then
    -- Reaching here now means genuinely unreadable or over the cap, not merely
    -- large. That is an UNSCORED request, so it answers to `fail_closed` like any
    -- other degraded check rather than quietly proxying -- which is what it used
    -- to do, in the one case where the body was too big to be boring.
    return degraded(conf, "request body", body_err or "empty body", nil, false)
  end

  local req = cjson.decode(raw)
  if type(req) ~= "table" then
    log_warn("request body is not JSON; forwarding unscored")
    return
  end

  -- Kept for the response phase and for the denial's shape. `stream` decides
  -- whether a block has to be rendered as SSE.
  ctx.straiker_request   = req
  ctx.straiker_model     = req.model
  ctx.straiker_streaming = req.stream == true
  ctx.straiker_session   = conversation_id(conf, req)
  -- Read HERE, in a real phase, because the streaming relay runs in a timer where
  -- `kong.request` is unavailable. See `hint_headers`.
  ctx.straiker_cc_session = kong.request.get_header("x-claude-code-session-id")

  if conf.debug_preamble then
    local sys, shape = req.system, type(req.system)
    if shape == "table" then
      sys = (sys[1] and (sys[1].text or cjson.encode(sys[1]))) or ""
      shape = "list[" .. tostring(#req.system) .. "]"
    end
    kong.log.warn(string.format("preamble shape=%s lead=%q", shape,
                                string.sub(tostring(sys or ""), 1, 150)))
  end

  -- Not needed in buffered mode: implementing `response` makes Kong buffer on its
  -- own. Calling it anyway would be harmless but would imply the phase is optional.

  -- Everything above is state the RESPONSE half needs, so it runs either way.
  -- Only the prompt's own scoring call is skipped here.
  if not conf.score_request then return end

  -- A shallow copy: the enrichment must not reach the body Kong forwards upstream.
  local scored = {}
  for k, v in pairs(req) do scored[k] = v end
  local verdict, err = score(conf, with_identity(conf, ctx, scored),
                             ctx.straiker_cc_session)
  if not verdict then
    return degraded(conf, "request", err, req.model, ctx.straiker_streaming)
  end

  kong.response.set_header(VERDICT_HEADER, decision_of(verdict) or "unknown")
  if blocked(verdict) then
    -- ⚠️ A pre-call block still runs header_filter, body_filter and log, so the
    -- post-call relay below would fire for a request that never reached the model
    -- and Straiker would see two turns for one. This flag is what stops that.
    ctx.straiker_denied = true
    return deny(block_text(verdict), req.model, ctx.straiker_streaming)
  end
end


-- --------------------------------------------------------------------------
-- The answer: envelope shared by both modes.
--
-- `{straiker_phase, sse, model, request}` is the envelope Straiker expects for an
-- answer. The nested `request` is not optional decoration: it is what identifies
-- the traffic, since the system preamble and the messages array live in there,
-- while the answer itself is scored from `sse` at the top level. Two different
-- questions of the same bytes. Omit it and the answer is classified against nothing.
-- --------------------------------------------------------------------------

local function answer_envelope(conf, ctx, body, phase)
  -- `session_id` at the envelope's OWN top level, because that is the only place it
  -- is read from; the nested request is for identification only.
  return with_identity(conf, ctx, {
    straiker_phase = phase,
    sse            = body,
    model          = ctx.straiker_model,
    request        = ctx.straiker_request,
  })
end


-- ⚠️ **Attached conditionally, and the `if` is load-bearing rather than tidy.**
-- Kong reads this table once and refuses the plugin outright if both shapes are
-- present, so these must be absent rather than merely inert. A plugin that fails to
-- load takes the WHOLE declarative config with it, not just itself.

if MODE == "buffered" then

  -- Kong is still holding the answer, so a block can still withhold it.
  function Straiker:response(conf)
    local ctx = ngx.ctx
    if not conf.score_response then return end
    -- A pre-call block still runs the later phases, so without this Straiker would
    -- see two turns for a request that never reached the model.
    if ctx.straiker_denied then return end

    -- ⚠️ **An upstream ERROR is not the model's answer.** Without this a 400, 401, 429 or
    -- 502 has its error JSON posted as `sse` and scored as though the model had said it.
    -- That records a turn nobody wrote, and on a rate-limited session it records one per
    -- retry: Claude Code's budget is 10, and it retries 429 and 529.
    --
    -- The prompt was already scored in `access`, so nothing is lost by staying quiet here.
    local status = kong.service.response.get_status()
    if not status or status < 200 or status >= 300 then
      kong.log.debug("upstream returned ", tostring(status), "; answer not scored")
      return
    end

    local body = kong.service.response.get_raw_body()
    if not body or body == "" then return end

    local verdict, err = score(conf, answer_envelope(conf, ctx, body, PHASE_BUFFERED),
                               ctx.straiker_cc_session)
    if not verdict then
      return degraded(conf, "response", err, ctx.straiker_model, ctx.straiker_streaming)
    end

    kong.response.set_header(VERDICT_HEADER, decision_of(verdict) or "unknown")
    if blocked(verdict) then
      -- `kong.response.set_raw_body()` raises here and 500s: it only works in
      -- `body_filter`. Exiting replaces the whole answer, which is what we want.
      return deny(block_text(verdict), ctx.straiker_model, ctx.straiker_streaming)
    end
  end

else

  -- Tokens pass through; the verdict is advisory and says so.
  function Straiker:body_filter(conf)
    if not conf.score_response then return end
    local ctx = ngx.ctx
    if ctx.straiker_denied then return end
    if ctx.straiker_skip_relay then return end

    -- ⚠️ **An upstream ERROR is not the model's answer, and this half had no such
    -- check while the buffered half did.** Without it a 400, 401, 429 or 502 has
    -- its error JSON relayed as `sse` and archived as a turn nobody wrote -- and on
    -- a rate-limited session, one per retry, because Claude Code's budget is 10 and
    -- it retries 429 and 529. The prompt was already scored in `access`, so nothing
    -- is lost by staying quiet. Same reasoning as the buffered branch; the two
    -- disagreeing is what made this a bug rather than a decision.
    local status = kong.response.get_status()
    if not status or status < 200 or status >= 300 then
      ctx.straiker_skip_relay = true
      ctx.straiker_chunks = nil
      return
    end

    local chunk = ngx.arg[1]
    if chunk and chunk ~= "" then
      -- ⚠️ **Bounded, because this buffer is worker memory held for the life of the
      -- request and nothing else caps it.** `max_body_bytes` was only consulted
      -- inside `score()` -- i.e. AFTER the whole answer had been concatenated -- so
      -- an oversized response was accumulated in full and only then thrown away.
      -- Stop accumulating at the limit instead.
      local len = (ctx.straiker_bytes or 0) + #chunk
      if len > conf.max_body_bytes then
        ctx.straiker_skip_relay = true
        ctx.straiker_chunks = nil
        log_warn("answer exceeded max_body_bytes (%d); relay skipped",
                 conf.max_body_bytes)
        return
      end
      ctx.straiker_bytes = len
      ctx.straiker_chunks = ctx.straiker_chunks or {}
      ctx.straiker_chunks[#ctx.straiker_chunks + 1] = chunk
    end
  end

  function Straiker:log(conf)
    if not conf.score_response then return end
    local ctx = ngx.ctx
    if ctx.straiker_denied or ctx.straiker_skip_relay then return end
    if not ctx.straiker_chunks then return end

    local payload = answer_envelope(conf, ctx, table.concat(ctx.straiker_chunks),
                                    PHASE_STREAMING)
    -- Pulled out of ctx HERE, while the request still exists. The timer below gets
    -- a fresh ngx.ctx, so anything it needs has to be an upvalue by then.
    local cc_session = ctx.straiker_cc_session

    -- ⚠️ Cosockets are UNAVAILABLE in `log_by_lua`. `resty.http` there fails with
    -- "API disabled in the context of log_by_lua*", the phase aborts, and the
    -- post-call silently never happens -- no error reaches anything watching.
    -- Deferring by zero seconds moves the call into a timer context where sockets
    -- work. This is also why the buffered shape cannot simply live here instead:
    -- by the time a timer runs, the answer has long since left.
    local ok, err = ngx.timer.at(0, function(premature)
      if premature then return end
      local verdict, serr = score(conf, payload, cc_session)
      if not verdict then
        log_warn("relay scoring failed: %s", serr or "unknown")
      elseif blocked(verdict) then
        -- Advisory by construction: the client already has these bytes. Said out
        -- loud so a log reader is not misled into thinking something was stopped.
        log_warn("relay verdict was BLOCK but the answer had already streamed: %s",
                 table.concat(verdict.blocked_by or {}, ", "))
      end
    end)
    if not ok then log_warn("could not schedule the relay: %s", err or "unknown") end
  end

end


return Straiker
