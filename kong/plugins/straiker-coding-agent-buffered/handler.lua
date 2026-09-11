-- Straiker Defend coding-agent detection — BUFFERED variant.
--
-- Attach where a tool call must be stopped before it executes (CI,
-- unattended agents). Kong buffers the upstream response until Straiker
-- Defend scores it. Interactive developers who need token-by-token
-- streaming should use straiker-coding-agent-streaming instead.
--
-- WHY A SECOND PLUGIN, NOT A FLAG. Kong sets ctx.buffered_proxying from
-- the existence of a `response` field on this table, before any plugin
-- code runs. A config flag cannot switch it. `response` cannot coexist
-- with body_filter, which is why this variant has no async relay.
--
-- Never attach both coding-agent plugins to the same route.
-- Do not combine this plugin with ai-proxy on streaming requests:
-- ai-proxy disables response buffering, and enforcement silently stops.
--
-- SELF-CONTAINED BY REQUIREMENT. Kong streaming custom plugins accept only
-- handler.lua and schema.lua and cannot require() a sibling module, so the
-- request path is duplicated here rather than shared. See the SHARED CORE
-- banner below before editing.

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

local function fail_open_response(tag)
  set_log{ response_verdict = tag }
  kong.response.set_header("x-straiker-response-verdict", tag)
end

-- ---------------------------------------------------------------------------
-- Buffered variant: score before the client sees the response
-- ---------------------------------------------------------------------------

local function straiker_inspect_response(conf)
  local S = kong.ctx.plugin

  if S.denied then return end
  if not S.sid or S.kind ~= "main" then return end

  local raw, err = kong.service.response.get_raw_body()
  if not raw or raw == "" then
    if err then kong.log.err(LOG_PREFIX, " no response body: ", tostring(err)) end
    return
  end
  if #raw > conf.max_response_bytes then
    kong.log.warn(LOG_PREFIX, " response exceeded ", conf.max_response_bytes,
                  " bytes; not scored for sid=", S.sid)
    return
  end

  local payload = cjson.encode({
    straiker_phase = "response-sync", sse = raw, model = S.model,
  })
  if not payload then
    kong.log.err(LOG_PREFIX, " response encode failed sid=", S.sid)
    return
  end

  local res, perr = post(conf, payload,
    detect_headers(conf, "response-sync", S.rid,
                   { ["x-claude-code-session-id"] = S.sid }),
    conf.timeout_ms)

  if not res then
    kong.log.err(LOG_PREFIX, " response scoring unreachable sid=", S.sid,
                 " err=", tostring(perr))
    if is_fail_closed(conf) then
      return kong.response.exit(503, { type = "error",
        error = { type = "api_error", message = "Straiker unavailable." } })
    end
    fail_open_response("fail-open-unreachable")
    return
  end
  if res.status ~= 200 then
    kong.log.err(LOG_PREFIX, " response scoring status ", res.status,
                 " sid=", S.sid, " ", string.sub(res.body or "", 1, 200))
    if is_fail_closed(conf) then
      return kong.response.exit(503, { type = "error",
        error = { type = "api_error", message = "Straiker error." } })
    end
    fail_open_response("fail-open-http-" .. tostring(res.status))
    return
  end

  local pok, info = pcall(read_verdict, res.body, S.stream)
  if not pok then
    kong.log.err(LOG_PREFIX, " response parse error (fail-open): ", tostring(info))
    fail_open_response("fail-open-parse")
    return
  end

  kong.log.notice(LOG_PREFIX, " response verdict=", info.verdict,
                  " scored=", info.scored,
                  " replayed=", info.replayed,
                  " top_score=", info.top_score,
                  " top_category=", info.top_cat)

  set_log{
    response_verdict      = info.verdict,
    response_scored       = info.scored,
    response_replayed     = info.replayed,
    response_top_score    = info.top_score,
    response_top_category = info.top_cat,
  }

  if info.verdict ~= "deny" then
    kong.response.set_header("x-straiker-response-verdict", "allow")
    return
  end

  set_log{
    verdict          = "deny",
    blocked_category = info.category,
    blocked_phase    = "response-sync",
  }

  kong.log.warn(LOG_PREFIX, " RESPONSE DENY ", info.category,
                " — tool call suppressed")
  return deny_exit(info.reason, info.model, "msg_straiker_" .. tostring(S.rid),
                   S.stream, {
    ["x-straiker-verdict"]  = "deny",
    ["x-straiker-category"] = info.category,
    ["x-straiker-phase"]    = "response-sync",
  })
end


-- ---------------------------------------------------------------------------
-- Plugin
-- ---------------------------------------------------------------------------

local StraikerCodingAgentBuffered = {
  -- Above ai-proxy (770) so get_raw_body() is the untranslated client body.
  -- Below Kong auth (key-auth 1250, jwt 1450) so the consumer is resolved.
  PRIORITY = 1000,
  VERSION  = "0.11.1",
}


function StraikerCodingAgentBuffered:access(conf)
  return straiker_access(conf)
end


function StraikerCodingAgentBuffered:response(conf)
  return straiker_inspect_response(conf)
end


return StraikerCodingAgentBuffered
