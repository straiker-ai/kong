-- Straiker Defend webhook plugin — chat and application LLM traffic.
--
-- Pre-call and post-call events to the Straiker Defend webhook
-- (POST /api/v1/detect/webhook). Designed to run with AI Proxy /
-- AI Proxy Advanced.
--
-- SELF-CONTAINED BY REQUIREMENT. Kong streaming custom plugins (Konnect
-- Dedicated Cloud Gateways, Gateway 3.15+) accept exactly two files per
-- plugin — handler.lua and schema.lua — and cannot require() a sibling
-- module. What used to live in kong/plugins/straiker/helpers.lua is
-- inlined below rather than required.

local cjson = require "cjson.safe"

local StraikerHandler = {
  PRIORITY = 760,
  VERSION = "0.11.1",
}

local LOG_PREFIX = "[straiker]"
local DEFAULT_TIMEOUT_MS = 5000


-- ---------------------------------------------------------------------------
-- Helpers (formerly kong.plugins.straiker.helpers)
-- ---------------------------------------------------------------------------

local function extract_text_content(content)
  if type(content) == "string" then
    return content
  elseif type(content) == "table" then
    for _, part in ipairs(content) do
      if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
        return part.text
      end
    end
  end
  return ""
end

local function last_user_prompt(messages)
  if type(messages) ~= "table" then return "" end
  for i = #messages, 1, -1 do
    local m = messages[i]
    if m and m.role == "user" then
      return extract_text_content(m.content)
    end
  end
  return ""
end

local function decode_jwt_claims(headers, log_prefix, debug)
  local raw_token = kong.ctx.shared and kong.ctx.shared.authenticated_jwt_token
  if raw_token then
    if debug then
      kong.log.debug(log_prefix, " authenticated_jwt_token found in kong.ctx.shared")
    end
  else
    local auth = headers and (headers["authorization"] or headers["Authorization"])
    if auth then raw_token = auth:match("^[Bb]earer%s+(.+)$") end
  end
  if not raw_token then return nil end

  local payload_b64 = raw_token:match("^[^%.]+%.([^%.]+)%.")
  if not payload_b64 then return nil end

  local padded = payload_b64:gsub("%-", "+"):gsub("_", "/")
  padded = padded .. string.rep("=", (4 - (#padded % 4)) % 4)
  local json_str = ngx.decode_base64(padded)
  if not json_str then return nil end

  local ok, claims = pcall(cjson.decode, json_str)
  if ok and type(claims) == "table" then return claims end
  return nil
end

local function resolve_user_name(headers, body, log_prefix, debug)
  if headers["x-user-name"] then return headers["x-user-name"] end
  local claims = decode_jwt_claims(headers, log_prefix, debug)
  if claims then
    local user = claims.email or claims.preferred_username
                 or claims["cognito:username"] or claims.sub
    if type(user) == "string" and user ~= "" then
      if debug then
        kong.log.debug(log_prefix, " user from JWT: ", user)
      end
      return user
    end
  end
  if body and type(body.user) == "string" and body.user ~= "" then
    return body.user
  end
  return "kong"
end

local function parse_sse_chunks(buf)
  local chunks = {}
  local current_event = nil
  local data_lines = {}

  local function flush_chunk()
    if #data_lines == 0 and not current_event then return end

    local data = table.concat(data_lines, "\n")
    local chunk = {}
    if current_event then chunk.event = current_event end
    if data ~= "" then
      local ok, decoded = pcall(cjson.decode, data)
      chunk.data = ok and decoded or data
    end
    chunks[#chunks + 1] = chunk

    current_event = nil
    data_lines = {}
  end

  local normalized = buf:gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in (normalized .. "\n"):gmatch("([^\n]*)\n") do
    if line == "" then
      flush_chunk()
    else
      local event = line:match("^event:%s*(.*)$")
      if event then
        current_event = event
      else
        local data = line:match("^data:%s*(.*)$")
        if data then
          data_lines[#data_lines + 1] = data
        end
      end
    end
  end

  return chunks
end

local function block_payload(_, model)
  return 200, {
    id      = "chatcmpl-blocked",
    object  = "chat.completion",
    model   = model or "unknown",
    choices = {{
      index         = 0,
      message       = { role = "assistant", content = "I'm sorry, I'm unable to process that request." },
      finish_reason = "stop",
    }},
  }
end

local function read_original_body()
  local ai_ctx = ngx.ctx.ai_namespaced_ctx
  if ai_ctx and ai_ctx._global and type(ai_ctx._global.request_body) == "string" then
    local raw = ai_ctx._global.request_body
    if raw ~= "" then return raw, true end
  end
  return nil, false
end

local function build_webhook_payload(opts, log_prefix)
  local headers = opts.headers or {}
  local debug = opts.conf and opts.conf.debug
  local user_id = resolve_user_name(headers, opts.body, log_prefix, debug)
  local user_role = headers["x-user-role"] or "public"

  local consumer_block = {}
  local ok, consumer = pcall(function() return kong.client.get_consumer() end)
  if ok and consumer then
    consumer_block.id        = consumer.id
    consumer_block.username  = consumer.username
    consumer_block.custom_id = consumer.custom_id
  end

  local ai_ctx_out = nil
  local ai_ctx = ngx.ctx.ai_namespaced_ctx
  if ai_ctx and type(ai_ctx) == "table" then
    local mc = ai_ctx["merge-models-conf"]
    local conf = mc and mc.model_conf
    if conf then
      ai_ctx_out = {
        llm_format      = conf.llm_format,
        route_type      = conf.route_type,
        genai_category  = conf.genai_category,
        model           = conf.model,
      }
    end
  end

  local payload = {
    eventType   = opts.event_type,

    request = {
      body = opts.body,
      text = opts.prompt,
    },

    userInfo = {
      id   = user_id,
      role = user_role,
    },

    consumer = consumer_block,

    metadata = {
      session_id = headers["x-session-id"] or ngx.var.request_id or "kong-session",
      client_ip  = ngx.var.remote_addr or "127.0.0.1",
    },

    aiContext = ai_ctx_out,
  }

  return payload
end

local function add_webhook_response(webhook_payload, resp_body, app_response)
  webhook_payload.response = {
    stream = false,
    body = resp_body,
    text = app_response,
  }
  return webhook_payload
end

local function add_webhook_stream_response(webhook_payload, chunks)
  webhook_payload.response = {
    stream = true,
    chunks = chunks,
    text = cjson.null,
  }
  return webhook_payload
end

-- ---------------------------------------------------------------------------
-- Transport
-- ---------------------------------------------------------------------------

local function webhook_url(conf)
  local url = (conf.detect_url or "https://api.prod.straiker.ai/api/v1/detect/webhook"):gsub("%?.*$", "")
  if url:sub(-15) == "/detect/webhook" then
    return url
  end
  if url:sub(-7) == "/detect" then
    return url .. "/webhook"
  end
  return url
end

local _http_mod
local function get_http()
  if _http_mod == nil then
    local ok, mod = pcall(require, "resty.http")
    _http_mod = ok and mod or false
  end
  return _http_mod or nil
end

local _gzip_mod
local function get_gzip()
  if _gzip_mod == nil then
    local ok, mod = pcall(require, "kong.tools.gzip")
    _gzip_mod = ok and mod or false
  end
  return _gzip_mod or nil
end

local function read_request_body()
  ngx.req.read_body()
  local raw = ngx.req.get_body_data()
  if raw then return raw end
  local ok_file, body_file = pcall(function() return ngx.req.get_body_file() end)
  if ok_file and body_file then
    local ok_io, content = pcall(function()
      local f = io.open(body_file, "rb")
      if not f then return nil end
      local c = f:read("*a")
      f:close()
      return c
    end)
    if ok_io and content then return content end
  end
  return nil
end

local function call_straiker(conf, payload)
  local http = get_http()
  if not http then
    return nil, "resty.http unavailable (plugin sandbox)"
  end
  local httpc = http.new()
  httpc:set_timeout(DEFAULT_TIMEOUT_MS)
  local body_json = cjson.encode(payload)
  if conf.debug then
    kong.log.notice(LOG_PREFIX, " >>> straiker request: ", body_json)
  end
  local res, err = httpc:request_uri(webhook_url(conf), {
    method = "POST",
    body = body_json,
    headers = {
      ["Authorization"] = "Bearer " .. conf.api_key,
      ["Content-Type"] = "application/json",
      ["X-Straiker-Webhook-Format"] = "kong-gateway",
    },
    ssl_verify = true,
    keepalive_timeout = 60000,
    keepalive_pool = 10,
  })
  if conf.debug and res then
    kong.log.notice(LOG_PREFIX, " <<< straiker response: status=", res.status, " body=", res.body)
  end
  return res, err
end

local function should_block(conf, result)
  return conf.block and type(result.action) == "string" and result.action:lower() == "block"
end

------------------------------------------------------------
-- access
------------------------------------------------------------

function StraikerHandler:access(conf)
  kong.service.request.enable_buffering()
  kong.service.request.set_header("Accept-Encoding", "identity")

  local raw, from_ai = read_original_body()
  if conf.debug and from_ai then
    kong.log.notice(LOG_PREFIX, " using original request body from ai-proxy context")
  end
  if not raw or raw == "" then
    raw = read_request_body()
  end
  if not raw or raw == "" then return end

  local body = cjson.decode(raw)
  if not body then return end

  local prompt = last_user_prompt(body.messages)
  if prompt == "" then return end

  if conf.debug then
    kong.log.notice(LOG_PREFIX, " request body: ", raw)
  end

  kong.ctx.plugin.prompt = prompt
  kong.ctx.plugin.model = body.model
  kong.ctx.plugin.headers = ngx.req.get_headers()

  local webhook = build_webhook_payload({
    conf = conf,
    body = body,
    prompt = prompt,
    headers = kong.ctx.plugin.headers,
    event_type = "pre_call",
  }, LOG_PREFIX)
  kong.ctx.plugin.webhook = webhook
  if conf.debug then
    kong.log.notice(LOG_PREFIX, " webhook pre_call: ", cjson.encode(webhook))
  end

  local res, err = call_straiker(conf, webhook)

  -- fail_open governs the INPUT gate when the webhook is unreachable / non-200:
  -- true (default) = allow through; false = fail CLOSED (block the unscored request).
  if not res then
    kong.log.err(LOG_PREFIX, " pre-call failed: ", err)
    if conf.fail_open then return end
    return kong.response.exit(503, {
      error = { message = "Straiker unavailable: " .. tostring(err), code = "503" },
    })
  end

  if res.status ~= 200 then
    kong.log.err(LOG_PREFIX, " pre-call non-200: ", res.status, " body: ", res.body)
    if conf.fail_open then return end
    return kong.response.exit(503, {
      error = { message = "Straiker returned " .. res.status, code = "503" },
    })
  end

  local result = cjson.decode(res.body) or {}
  local score = tonumber(result.score) or 0
  if conf.debug then
    kong.log.notice(LOG_PREFIX, " pre-call action=", tostring(result.action),
      " score=", score, " turn_id=", (result.turn_id or result.turnId or "n/a"))
  end

  if should_block(conf, result) then
    kong.ctx.plugin.blocked = true
    local status, payload_tbl = block_payload(conf, kong.ctx.plugin.model)
    return kong.response.exit(status, payload_tbl)
  end
end

------------------------------------------------------------
-- response
------------------------------------------------------------

function StraikerHandler:response(conf)
  if not kong.ctx.plugin.prompt then return end
  if kong.ctx.plugin.blocked then return end

  local raw_body = kong.response.get_raw_body()
  if not raw_body or raw_body == "" then return end

  if conf.debug then
    kong.log.notice(LOG_PREFIX, " response body: ", raw_body)
  end

  local looks_gzip = #raw_body >= 2 and raw_body:byte(1) == 0x1f and raw_body:byte(2) == 0x8b
  if looks_gzip then
    local gzip = get_gzip()
    if gzip then
      local ok, inflated = pcall(gzip.inflate_gzip, raw_body)
      if ok and inflated and #inflated > 0 then raw_body = inflated end
    end
  end

  local ct = kong.service.response.get_header("Content-Type") or ""
  local is_sse = ct:find("text/event-stream", 1, true) ~= nil

  local app_response, has_tool_calls = "", false
  local stream_chunks = nil
  if is_sse then
    stream_chunks = parse_sse_chunks(raw_body)
  else
    local resp = cjson.decode(raw_body)
    if resp and resp.choices and resp.choices[1] and resp.choices[1].message then
      local msg = resp.choices[1].message
      local content = msg.content
      if content == nil or content == cjson.null or type(content) ~= "string" then
        app_response = ""
      else
        app_response = content
      end
      local tcs = msg.tool_calls
      has_tool_calls = type(tcs) == "table" and #tcs > 0
    elseif resp and type(resp.content) == "table" and (resp.type == "message" or resp.role == "assistant") then
      local parts = {}
      for _, block in ipairs(resp.content) do
        if block.type == "text" and type(block.text) == "string" then
          parts[#parts + 1] = block.text
        elseif block.type == "tool_use" then
          has_tool_calls = true
        end
      end
      app_response = table.concat(parts, "")
    end
  end

  local resp_body = cjson.decode(raw_body)
  local webhook = kong.ctx.plugin.webhook
  if kong.ctx.plugin.webhook then
    webhook.eventType = "post_call"
    if is_sse then
      add_webhook_stream_response(webhook, stream_chunks or {})
    else
      add_webhook_response(webhook, resp_body, app_response)
    end
    if conf.debug then
      kong.log.notice(LOG_PREFIX, " webhook post_call: ", cjson.encode(webhook))
    end
  end

  if has_tool_calls then return end
  if not is_sse and app_response == "" then return end

  if not webhook then return end

  local res, err = call_straiker(conf, webhook)
  if not res then
    kong.log.err(LOG_PREFIX, " response-eval failed: ", err)
    return
  end
  if res.status ~= 200 then
    kong.log.err(LOG_PREFIX, " response-eval non-200: ", res.status, " body: ", res.body)
    return
  end

  local result = cjson.decode(res.body) or {}
  local score = tonumber(result.score) or 0
  if conf.debug then
    kong.log.notice(LOG_PREFIX, " response-eval action=", tostring(result.action),
      " score=", score, " turn_id=", (result.turn_id or result.turnId or "n/a"))
  end

  if should_block(conf, result) then
    kong.log.notice(LOG_PREFIX, " BLOCKING response action=", tostring(result.action))
    local status, payload_tbl = block_payload(conf, kong.ctx.plugin.model)
    return kong.response.exit(status, payload_tbl)
  end
end

return StraikerHandler
