local cjson = require "cjson.safe"
local helpers = require "kong.plugins.straiker-shared.helpers"

local StraikerSaaS = {
  PRIORITY = 760,
  VERSION = "0.8.0",
}

local LOG_PREFIX = "[straiker-saas]"

------------------------------------------------------------
-- lazy, sandbox-safe module loaders
------------------------------------------------------------

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

------------------------------------------------------------
-- handler-specific helpers
------------------------------------------------------------

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
  httpc:set_timeout(conf.timeout)
  local body_json = cjson.encode(payload)
  kong.log.notice(LOG_PREFIX, " >>> straiker request: ", body_json)
  local res, err = httpc:request_uri(helpers.detect_url(conf), {
    method = "POST",
    body = body_json,
    headers = {
      ["Authorization"] = "Bearer " .. conf.api_key,
      ["Content-Type"] = "application/json",
      ["X-Straiker-Smart-Publish"] = "true",
    },
    ssl_verify = true,
    keepalive_timeout = 60000,
    keepalive_pool = 10,
  })
  if res then
    kong.log.notice(LOG_PREFIX, " <<< straiker response: status=", res.status, " body=", res.body)
  end
  return res, err
end

------------------------------------------------------------
-- access
------------------------------------------------------------

function StraikerSaaS:access(conf)
  if conf.mode ~= "pre_call" then
    kong.service.request.enable_buffering()
    kong.service.request.set_header("Accept-Encoding", "identity")
  end

  local raw, from_ai = helpers.read_original_body()
  if from_ai then
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

  kong.log.notice(LOG_PREFIX, " request body: ", raw)

  kong.ctx.plugin.prompt = prompt
  kong.ctx.plugin.model = body.model
  kong.ctx.plugin.messages = body.messages
  kong.ctx.plugin.tools = body.tools
  kong.ctx.plugin.body = body
  kong.ctx.plugin.headers = ngx.req.get_headers()

  local ai_provider, ai_model_id = helpers.resolve_ai_model_info()
  kong.ctx.plugin.model_provider = ai_provider
  kong.ctx.plugin.model_id = ai_model_id
  kong.log.debug(LOG_PREFIX, " ai model: provider=", tostring(ai_provider), " model_id=", tostring(ai_model_id))

  local dynamic_source = helpers.resolve_app_source(conf, kong.ctx.plugin.headers, LOG_PREFIX)
  if dynamic_source then
    kong.ctx.plugin.dynamic_source = dynamic_source
    kong.log.notice(LOG_PREFIX, " app source resolved: ", dynamic_source)
  end

  if conf.mode == "post_call" and not conf.blocking then return end

  local last_msg = body.messages and body.messages[#body.messages]
  if conf.agentic and not conf.blocking and last_msg
     and (last_msg.role == "tool" or last_msg.role == "assistant") then
    return
  end

  local payload = helpers.build_payload({
    conf = conf,
    prompt = prompt,
    app_response = "N/A",
    model = body.model,
    headers = kong.ctx.plugin.headers,
    body = body,
    messages = body.messages,
    tools = body.tools,
    hook = "pre_call",
    dynamic_source = kong.ctx.plugin.dynamic_source,
    model_provider = kong.ctx.plugin.model_provider,
    model_id = kong.ctx.plugin.model_id,
  }, LOG_PREFIX)

  local res, err = call_straiker(conf, payload)

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
  kong.log.notice(LOG_PREFIX, " pre-call score=", score, " turn_id=", (result.turn_id or result.turnId or "n/a"))

  if score > conf.threshold then
    kong.ctx.plugin.blocked = true
    local status, payload_tbl = helpers.block_payload(conf, kong.ctx.plugin.model)
    return kong.response.exit(status, payload_tbl)
  end
end

------------------------------------------------------------
-- response
------------------------------------------------------------

function StraikerSaaS:response(conf)
  if conf.mode == "pre_call" then return end
  if not kong.ctx.plugin.prompt then return end
  if kong.ctx.plugin.blocked then return end

  local raw_body = kong.service.response.get_raw_body()
  if not raw_body or raw_body == "" then return end

  kong.log.notice(LOG_PREFIX, " response body: ", raw_body)

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

  local app_response, has_tool_calls, final_tool_calls = "", false, nil
  if is_sse then
    local content, tool_calls = helpers.parse_sse_buffer(raw_body)
    app_response = content
    has_tool_calls = tool_calls ~= nil
    final_tool_calls = tool_calls
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
      if has_tool_calls then final_tool_calls = tcs end
    elseif resp and type(resp.content) == "table" and (resp.type == "message" or resp.role == "assistant") then
      local parts = {}
      for _, block in ipairs(resp.content) do
        if block.type == "text" and type(block.text) == "string" then
          parts[#parts + 1] = block.text
        elseif block.type == "tool_use" then
          has_tool_calls = true
          if not final_tool_calls then final_tool_calls = {} end
          final_tool_calls[#final_tool_calls + 1] = {
            id = block.id,
            type = "function",
            ["function"] = {
              name = block.name,
              arguments = type(block.input) == "table" and cjson.encode(block.input) or tostring(block.input or ""),
            },
          }
        end
      end
      app_response = table.concat(parts, "")
    end
  end

  if conf.agentic and has_tool_calls then return end
  if app_response == "" then return end

  local payload = helpers.build_payload({
    conf = conf,
    prompt = kong.ctx.plugin.prompt,
    app_response = app_response,
    model = kong.ctx.plugin.model,
    headers = kong.ctx.plugin.headers or {},
    body = kong.ctx.plugin.body,
    messages = kong.ctx.plugin.messages,
    tools = kong.ctx.plugin.tools,
    hook = "post_call",
    dynamic_source = kong.ctx.plugin.dynamic_source,
    final_tool_calls = final_tool_calls,
    model_provider = kong.ctx.plugin.model_provider,
    model_id = kong.ctx.plugin.model_id,
  }, LOG_PREFIX)

  local res, err = call_straiker(conf, payload)
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
  kong.log.notice(LOG_PREFIX, " response-eval score=", score, " turn_id=", (result.turn_id or result.turnId or "n/a"))

  if conf.block_response and score > conf.threshold then
    kong.log.notice(LOG_PREFIX, " BLOCKING response (score=", score, " > ", conf.threshold, ")")
    local status, payload_tbl = helpers.block_payload(conf, kong.ctx.plugin.model)
    return kong.response.exit(status, payload_tbl)
  end
end

return StraikerSaaS
