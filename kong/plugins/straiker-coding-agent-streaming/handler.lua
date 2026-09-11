-- Straiker Defend coding-agent detection — STREAMING variant.
--
-- Attach to interactive developer routes. Responses stream to the client
-- untouched. Prompt inspection and IPI (poisoned tool results on the next
-- request) are enforced; a tool_use cannot be suppressed before the client
-- runs it — that is the buffered plugin.
--
-- Never attach both coding-agent plugins to the same route.
--
-- SELF-CONTAINED BY REQUIREMENT. Kong streaming custom plugins accept only
-- handler.lua and schema.lua and cannot require() a sibling module, so the
-- request path is duplicated here rather than shared. See the SHARED CORE
-- banner below before editing.
--
-- ON TIMERS AND DEDICATED CLOUD GATEWAYS. Kong documents that a streamed
-- custom plugin "cannot run in the init_worker phase or create timers".
-- straiker_relay() ships the model's response from ngx.timer.at because
-- log_by_lua forbids cosockets and resty.http is built on them -- once the
-- bytes have shipped there is no other way to make the call.
--
-- The sandbox does not in fact block it: kong/tools/sandbox/configuration.lua
-- hands a plugin the whole ngx global in every mode, commented "including
-- timers, :-(". Read the restriction as a request not to -- a timer outlives
-- the request holding a closure over conf, which is a hazard when the control
-- plane hot-swaps streamed code -- rather than as a wall.
--
-- If a spawn is ever refused the plugin warns and continues; request-phase
-- enforcement is unaffected. Set relay_response = false to stop trying, or use
-- the buffered plugin, which scores the response inline and needs no timer.
--
-- The setting that DOES stop this plugin loading is KONG_UNTRUSTED_LUA. Kong
-- defaults it to "strict", which refuses require("resty.http") outright. Use
-- "lax" or "on"; see README, Konnect Dedicated Cloud Gateways.

-- ---------------------------------------------------------------------------
-- >>> BEGIN SHARED CORE <<<
--
-- Byte-identical with the other straiker-coding-agent-* handler.
--
-- Kong streaming custom plugins (Konnect Dedicated Cloud Gateways, Gateway
-- 3.15+) accept exactly two files per plugin -- handler.lua and schema.lua --
-- and cannot require() a sibling module. The request path that used to live
-- once in kong/plugins/straiker/coding_agent.lua is therefore duplicated into
-- each variant. Edit one copy and you must edit the other:
-- tools/check-shared-blocks.sh fails when the two drift.
--
-- This block forwards Anthropic Messages bodies to Straiker Defend
-- (POST /api/v1/detect). Event synthesis, sidecar filtering, replay dedup,
-- and every policy decision happen in Straiker Defend -- not here.
-- ---------------------------------------------------------------------------

local http  = require "resty.http"
local cjson = require "cjson.safe"

local LOG_PREFIX = "[straiker-coding-agent]"
local X_TOOL = "kong-claude-code"

local FORWARD = {
  "x-claude-code-session-id",
  "x-claude-code-agent-id",
  "x-claude-code-parent-agent-id",
  "x-app",
}


-- ---------------------------------------------------------------------------
-- Deny response (formerly kong.plugins.straiker.coding_agent_deny)
--
-- Synthesize a Straiker Defend block as an Anthropic Messages assistant turn.
-- Always HTTP 200. Coding-agent clients such as Claude Code map 403 to
-- "Please run /login", retry 408/409/429/5xx/529, and treat stop_reason
-- "refusal" as an Anthropic Acceptable Use Policy kill. A completed
-- end_turn keeps the session alive and shows the policy text to the user.
-- ---------------------------------------------------------------------------

local DENY_STOP_REASON = "end_turn"

local EMPTY_ARRAY = cjson.empty_array
                    or (cjson.array_mt and setmetatable({}, cjson.array_mt))
                    or {}


local function sse(event, data)
  return "event: " .. event .. "\ndata: " .. cjson.encode(data) .. "\n\n"
end


--- Replace the upstream response with a policy message the developer can read.
-- @param reason  human-facing text from Detect `stopReason` (never
--                `permissionDecisionReason`, which is addressed to the model)
-- @param streaming  whether the client asked for SSE
local function deny_exit(reason, model, msg_id, streaming, headers)
  if not streaming then
    headers["Content-Type"] = "application/json"
    return kong.response.exit(200, {
      id = msg_id, type = "message", role = "assistant", model = model,
      content = { { type = "text", text = reason } },
      stop_reason = DENY_STOP_REASON, stop_sequence = cjson.null,
      usage = { input_tokens = 0, output_tokens = 0 },
    }, headers)
  end

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
      delta = { stop_reason = DENY_STOP_REASON, stop_sequence = cjson.null },
      usage = { output_tokens = 0 } }),
    sse("message_stop", { type = "message_stop" }),
  }), headers)
end

-- cjson.null is userdata and truthy in Lua. Indexing it throws; `x or default`
-- returns the null. Scalars go through nn(), tables through obj().
local function nn(v)
  if v == nil or v == cjson.null or v == "" then return nil end
  return v
end

local function obj(v)
  if type(v) == "table" then return v end
  return nil
end

local function is_fail_closed(conf)
  return conf.fail_open == false
end


local function has_key(conf)
  if conf.api_key and conf.api_key ~= "" then return true end
  kong.log.err(LOG_PREFIX, " api_key is empty — vault reference unresolved? ",
               "env-vault names must be declared in nginx_main_env")
  return false
end


local function request_id()
  return tostring((kong.request.get_id and kong.request.get_id())
                  or ngx.var.request_id or "0")
end


--- Identity from Kong, never from a client-forged body field.
-- Priority 1000 sits below Kong auth plugins (key-auth 1250, jwt 1450) so
-- the consumer is already resolved. An unauthenticated route yields nil
-- and Straiker Defend archives the turn without a user_name.
local function resolve_user()
  local get_consumer = kong.client and kong.client.get_consumer
  local consumer = get_consumer and get_consumer()
  if consumer and consumer.username and consumer.username ~= "" then
    return consumer.username
  end
  local hdr = kong.request.get_header("x-consumer-username")
  if hdr and hdr ~= "" then return hdr end
  return nil
end


--- Captured in access: the async relay runs in ngx.timer after the request
-- context is gone, so it cannot call kong.request / kong.client.
local function identity_headers()
  local h = kong.request.get_headers()
  local out = {}
  for _, name in ipairs(FORWARD) do
    if h[name] then out[name] = h[name] end
  end
  local user = resolve_user()
  if user then out["x-straiker-user"] = user end
  -- Bedrock carries the model in the URL; adapters may set this header.
  if h["x-straiker-model"] then out["x-straiker-model"] = h["x-straiker-model"] end
  return out
end


local function detect_headers(conf, phase, rid, extra)
  local out = {
    ["Content-Type"]          = "application/json",
    ["Authorization"]         = "Bearer " .. conf.api_key,
    ["x-tool"]                = X_TOOL,
    ["x-straiker-phase"]      = phase,
    ["x-straiker-request-id"] = rid,
  }
  for k, v in pairs(identity_headers()) do out[k] = v end
  for k, v in pairs(extra or {}) do out[k] = v end
  return out
end


local function post(conf, body, headers, timeout_ms)
  local httpc = http.new()
  httpc:set_timeout(timeout_ms)
  return httpc:request_uri(conf.detect_url, {
    method = "POST", body = body, headers = headers, ssl_verify = true,
    keepalive_timeout = 60000,
    keepalive_pool = 10,
  })
end


local function set_log(fields)
  local S = kong.ctx.plugin
  local merged = S.log_fields or {}
  for k, v in pairs(fields) do merged[k] = v end
  S.log_fields = merged
  kong.log.set_serialize_value("straiker", merged)
end


local function fail_open(tag)
  set_log{ verdict = tag }
  kong.response.set_header("x-straiker-verdict", tag)
end


local function read_verdict(res_body, streaming)
  local parsed = obj(cjson.decode(res_body or ""))
  local hook   = obj(parsed and parsed.hookSpecificOutput)
  local st     = obj(parsed and parsed.straiker)
  local bb     = obj(st and st.blocked_by)

  local top_score, top_cat = 0, "-"
  for _, e in ipairs(obj(st and st.events) or {}) do
    if (e.score or 0) >= top_score then
      top_score = e.score or 0
      top_cat = nn(e.score_category) or "-"
    end
  end

  return {
    verdict = nn(hook and hook.permissionDecision) or "allow",
    reason  = nn(parsed and parsed.stopReason)
              or nn(hook and hook.permissionDecisionReason)
              or "Blocked by Straiker policy.",
    category  = nn(bb and bb.score_category) or top_cat,
    model     = nn(st and st.model) or "claude-sonnet-4-5",
    sid       = nn(st and st.session_id),
    kind      = nn(st and st.call_kind) or "-",
    phase     = nn(st and st.phase) or "-",
    scored    = nn(st and st.events_scored) or 0,
    replayed  = nn(st and st.events_replayed) or 0,
    top_score = top_score,
    top_cat   = top_cat,
    stream    = streaming,
  }
end


-- ---------------------------------------------------------------------------
-- Request side — identical in both variants
-- ---------------------------------------------------------------------------

local function straiker_access(conf)
  if kong.request.get_method() ~= "POST" then return end

  -- Anchored at the end. Claude Code also POSTs /v1/messages/count_tokens
  -- with the full conversation; a substring match would score those first
  -- and let replay-dedup suppress the real turn.
  local path = kong.request.get_path() or ""
  if not path:match("/v1/messages/?$") then
    return
  end

  if not has_key(conf) then
    if is_fail_closed(conf) then
      return kong.response.exit(500, { type = "error",
        error = { type = "api_error", message = "Straiker not configured." } })
    end
    fail_open("fail-open-no-key")
    return
  end

  local body, body_err = kong.request.get_raw_body()
  if not body then
    kong.log.err(LOG_PREFIX, " no raw body: ", tostring(body_err),
                 " — raise nginx_http_client_body_buffer_size to 32m")
    fail_open("fail-open-no-body")
    return
  end

  kong.service.request.set_header("Accept-Encoding", "identity")

  local rid = request_id()
  local res, err = post(conf, body, detect_headers(conf, "request", rid),
                        conf.timeout_ms)

  if not res then
    kong.log.err(LOG_PREFIX, " unreachable: ", tostring(err))
    if is_fail_closed(conf) then
      return kong.response.exit(503, { type = "error",
        error = { type = "api_error", message = "Straiker unavailable." } })
    end
    fail_open("fail-open-unreachable")
    return
  end

  if res.status ~= 200 then
    if res.status == 401 then
      kong.log.err(LOG_PREFIX, " 401 — api_key rejected")
    else
      kong.log.err(LOG_PREFIX, " unexpected status ", res.status, ": ",
                   string.sub(res.body or "", 1, 300))
    end
    if is_fail_closed(conf) then
      return kong.response.exit(503, { type = "error",
        error = { type = "api_error", message = "Straiker error." } })
    end
    fail_open("fail-open-http-" .. tostring(res.status))
    return
  end

  local pok, info = pcall(function()
    local streaming = (obj(cjson.decode(body)) or {}).stream == true
    return read_verdict(res.body, streaming)
  end)

  if not pok then
    kong.log.err(LOG_PREFIX, " parse error (fail-open): ", tostring(info))
    fail_open("fail-open-parse")
    return
  end

  local S = kong.ctx.plugin
  S.sid    = info.sid
  S.model  = info.model
  S.kind   = info.kind
  S.rid    = rid
  S.stream = info.stream
  S.ident  = identity_headers()

  kong.log.notice(LOG_PREFIX, " verdict=", info.verdict,
                  " scored=", info.scored,
                  " replayed=", info.replayed,
                  " kind=", info.kind,
                  " top_score=", info.top_score,
                  " top_category=", info.top_cat)

  set_log{
    verdict = info.verdict, session_id = info.sid or "-", call_kind = info.kind,
    events_scored = info.scored, events_replayed = info.replayed,
    top_score = info.top_score, top_category = info.top_cat,
    blocked_category = (info.verdict == "deny") and info.category or nil,
    blocked_phase = (info.verdict == "deny") and "request" or nil,
  }

  if info.verdict ~= "deny" then
    kong.response.set_header("x-straiker-verdict", "allow")
    return
  end

  kong.log.warn(LOG_PREFIX, " DENY ", info.category)
  S.denied = true
  return deny_exit(info.reason, info.model, "msg_straiker_" .. rid, info.stream, {
    ["x-straiker-verdict"]  = "deny",
    ["x-straiker-category"] = info.category,
  })
end

-- ---------------------------------------------------------------------------
-- >>> END SHARED CORE <<<
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Streaming variant: accumulate, then relay from a timer
-- ---------------------------------------------------------------------------

local function straiker_accumulate(conf)
  local S = kong.ctx.plugin
  if not S.sid or S.accum_over or S.denied then return end
  -- Same gates as relay(), applied before buffering rather than after: a
  -- response nothing will ever read still costs worker memory for every byte
  -- streamed. Sidecars (title generation, suggestion mode) are not turns.
  if not conf.relay_response or S.kind ~= "main" then return end

  local chunk = ngx.arg[1]
  if not chunk or chunk == "" then return end

  local buf = S.buf
  if not buf then
    buf = {}
    S.buf = buf
    S.len = 0
  end

  S.len = S.len + #chunk
  if S.len > conf.max_response_bytes then
    S.accum_over = true
    S.buf = nil
    kong.log.warn(LOG_PREFIX, " response exceeded ", conf.max_response_bytes,
                  " bytes; response telemetry skipped for sid=", S.sid)
    return
  end

  buf[#buf + 1] = chunk
end


--- After the stream has shipped. Monitor only: log_by_lua forbids cosockets,
-- so the POST runs in ngx.timer after the client already has every byte.
local function straiker_relay(conf)
  if not conf.relay_response then return end

  local S = kong.ctx.plugin
  local sid, buf = S.sid, S.buf
  if not sid or not buf or not has_key(conf) then return end
  if S.kind ~= "main" then return end

  local raw   = table.concat(buf)
  local model = S.model
  local rid   = S.rid
  local ident = S.ident or {}
  if raw == "" then return end

  local ok, err = ngx.timer.at(0, function(premature)
    if premature then return end

    local payload = cjson.encode({
      straiker_phase = "response", sse = raw, model = model,
    })
    if not payload then
      kong.log.err(LOG_PREFIX, " relay encode failed sid=", sid)
      return
    end

    local headers = {
      ["Content-Type"]             = "application/json",
      ["Authorization"]            = "Bearer " .. conf.api_key,
      ["x-tool"]                   = X_TOOL,
      ["x-straiker-phase"]         = "response",
      ["x-claude-code-session-id"] = sid,
      ["x-straiker-request-id"]    = rid,
    }
    for k, v in pairs(ident) do headers[k] = v end

    local res, perr = post(conf, payload, headers, conf.relay_timeout_ms)

    if not res then
      kong.log.err(LOG_PREFIX, " relay failed sid=", sid, " err=", tostring(perr))
      return
    end
    if res.status ~= 200 then
      kong.log.err(LOG_PREFIX, " relay status ", res.status, " sid=", sid, " ",
                   string.sub(res.body or "", 1, 200))
      return
    end
    kong.log.notice(LOG_PREFIX, " relay ok sid=", sid, " bytes=", #raw)
  end)

  if not ok then
    kong.log.warn(LOG_PREFIX, " relay timer spawn failed sid=", sid,
                  " err=", tostring(err))
  end
end


-- ---------------------------------------------------------------------------
-- Plugin
-- ---------------------------------------------------------------------------

local StraikerCodingAgentStreaming = {
  -- Above ai-proxy (770) so get_raw_body() is the untranslated client body.
  -- Below Kong auth (key-auth 1250, jwt 1450) so the consumer is resolved.
  PRIORITY = 1000,
  VERSION  = "0.11.1",
}


function StraikerCodingAgentStreaming:access(conf)
  return straiker_access(conf)
end


function StraikerCodingAgentStreaming:body_filter(conf)
  return straiker_accumulate(conf)
end


function StraikerCodingAgentStreaming:log(conf)
  return straiker_relay(conf)
end


return StraikerCodingAgentStreaming
