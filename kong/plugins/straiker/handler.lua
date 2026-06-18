local cjson = require "cjson.safe"
local helpers = require "kong.plugins.straiker.helpers"

local StraikerHandler = {
  PRIORITY = 760,
  VERSION = "0.10.0",
}

local LOG_PREFIX = "[straiker]"
local DEFAULT_TIMEOUT_MS = 5000

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

  local raw, from_ai = helpers.read_original_body()
  if conf.debug and from_ai then
    kong.log.notice(LOG_PREFIX, " using original request body from ai-proxy context")
  end
  if not raw or raw == "" then
    raw = read_request_body()
  end
  if not raw or raw == "" then return end

  local body = cjson.decode(raw)
  if not body then return end

  local prompt = helpers.last_user_prompt(body.messages)
  if prompt == "" then return end

  if conf.debug then
    kong.log.notice(LOG_PREFIX, " request body: ", raw)
  end

  kong.ctx.plugin.prompt = prompt
  kong.ctx.plugin.model = body.model
  kong.ctx.plugin.headers = ngx.req.get_headers()

  local webhook = helpers.build_webhook_payload({
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
    local status, payload_tbl = helpers.block_payload(conf, kong.ctx.plugin.model)
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
    stream_chunks = helpers.parse_sse_chunks(raw_body)
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
      helpers.add_webhook_stream_response(webhook, stream_chunks or {})
    else
      helpers.add_webhook_response(webhook, resp_body, app_response)
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
    local status, payload_tbl = helpers.block_payload(conf, kong.ctx.plugin.model)
    return kong.response.exit(status, payload_tbl)
  end
end

return StraikerHandler
