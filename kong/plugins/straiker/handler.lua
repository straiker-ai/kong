local http = require "resty.http"
local cjson = require "cjson.safe"
local kong_gzip = require "kong.tools.gzip"
local helpers = require "kong.plugins.straiker-shared.helpers"

local StraikerHandler = {
  PRIORITY = 760,
  VERSION = "0.8.0",
}

local LOG_PREFIX = "[straiker]"

------------------------------------------------------------
-- handler-specific helpers
------------------------------------------------------------

local function call_straiker(conf, payload)
  local httpc = http.new()
  httpc:set_timeout(conf.timeout)
  local body_json = cjson.encode(payload)
  ngx.log(ngx.DEBUG, LOG_PREFIX, " sending payload: ", body_json)
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
  return res, err
end

------------------------------------------------------------
-- MCP discovery
------------------------------------------------------------

local _mcp_seen = {}
local _MCP_DEDUP_TTL = 300

local function mcp_should_emit(key)
  local now = ngx.now()
  local exp = _mcp_seen[key]
  if exp and exp > now then
    return false
  end
  if not exp then
    local n = 0
    for _ in pairs(_mcp_seen) do n = n + 1 end
    if n > 1000 then _mcp_seen = {} end
  end
  _mcp_seen[key] = now + _MCP_DEDUP_TTL
  return true
end

local function mcp_server_identity(conf)
  local svc = kong.router.get_service()
  local host = (svc and svc.host) or "unknown-mcp"
  local proto = (svc and svc.protocol) or "http"
  local port = svc and svc.port
  local mcp_url = proto .. "://" .. host .. (port and (":" .. port) or "")
  local name = (conf.mcp_server_name and conf.mcp_server_name ~= ""
                and conf.mcp_server_name ~= "off") and conf.mcp_server_name
               or (svc and svc.name) or host
  return name, mcp_url
end

local function emit_mcp_discovery(conf, raw)
  local ok, rpc = pcall(cjson.decode, raw)
  if not ok or type(rpc) ~= "table" then return end
  local calls = rpc.method and { rpc } or rpc
  if type(calls) ~= "table" then return end

  local server_name, mcp_url = mcp_server_identity(conf)
  local source = (conf.mcp_source and conf.mcp_source ~= "" and conf.mcp_source ~= "off")
                 and conf.mcp_source or "kong"
  local app = kong.ctx.plugin.dynamic_source or conf.source or "Kong Default App"
  local detect = (conf.detect_url or "https://api.prod.straiker.ai/api/v1/detect"):gsub("%?.*$", "")
  local api_key = conf.api_key

  for _, call in ipairs(calls) do
    if type(call) == "table" and call.method == "tools/call"
       and type(call.params) == "table" and type(call.params.name) == "string" then
      local tool = call.params.name
      if mcp_should_emit(server_name .. "|" .. tool) then
        local event = cjson.encode({
          hook_event_name = "beforeMCPExecution",
          tool_name       = tool,
          mcp_server_name = server_name,
          mcp_url         = mcp_url,
          command         = server_name,
          user_name       = app,
          session_id      = "kong-mcp-" .. server_name,
        })
        ngx.timer.at(0, function(premature)
          if premature then return end
          local httpc = http.new()
          httpc:set_timeout(conf.timeout or 5000)
          local res, err = httpc:request_uri(detect, {
            method = "POST", body = event,
            ssl_verify = true,
            keepalive_timeout = 60000,
            keepalive_pool = 10,
            headers = {
              ["Content-Type"]  = "application/json",
              ["Authorization"] = "Bearer " .. api_key,
              ["x-tool"]        = source,
              ["X-Straiker-Smart-Publish"] = "true",
            },
          })
          if not res then
            kong.log.err(LOG_PREFIX, " mcp-discovery emit failed: ", err)
          else
            kong.log.notice(LOG_PREFIX, " mcp-discovery emit: server=", server_name,
              " tool=", tool, " source=", source, " http=", res.status)
          end
        end)
      end
    end
  end
end

------------------------------------------------------------
-- access
------------------------------------------------------------

function StraikerHandler:access(conf)
  if conf.mode ~= "pre_call" then
    ngx.req.set_header("Accept-Encoding", "identity")
  end

  local raw, from_ai = helpers.read_original_body()
  if not raw or raw == "" then
    ngx.req.read_body()
    raw = ngx.req.get_body_data()
    if not raw then
      local body_file = ngx.req.get_body_file()
      if body_file then
        local f = io.open(body_file, "rb")
        if f then
          raw = f:read("*a")
          f:close()
        end
      end
    end
  end
  if not raw or raw == "" then return end

  if conf.mcp_discovery then
    emit_mcp_discovery(conf, raw)
    return
  end

  local body = cjson.decode(raw)
  if not body then return end

  local prompt = helpers.last_user_prompt(body.messages)
  if prompt == "" then return end

  kong.ctx.plugin.prompt = prompt
  kong.ctx.plugin.model = body.model
  kong.ctx.plugin.messages = body.messages
  kong.ctx.plugin.tools = body.tools
  kong.ctx.plugin.body = body
  kong.ctx.plugin.headers = ngx.req.get_headers()

  local ai_provider, ai_model_id = helpers.resolve_ai_model_info()
  kong.ctx.plugin.model_provider = ai_provider
  kong.ctx.plugin.model_id = ai_model_id

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
-- header_filter / body_filter
------------------------------------------------------------

function StraikerHandler:header_filter(conf)
  if conf.mode == "pre_call" then return end
  ngx.header.content_length = nil
  local ct = ngx.header.content_type or ""
  kong.ctx.plugin.is_sse = ct:find("text/event-stream", 1, true) ~= nil
  local ce = ngx.header.content_encoding or ""
  kong.ctx.plugin.is_gzip = ce:lower():find("gzip", 1, true) ~= nil
end

function StraikerHandler:body_filter(conf)
  if conf.mode == "pre_call" then return end
  if not kong.ctx.plugin.prompt then return end

  local chunk = ngx.arg[1]
  local eof = ngx.arg[2]
  local parts = kong.ctx.plugin.body_parts
  if not parts then
    parts = {}
    kong.ctx.plugin.body_parts = parts
  end
  if chunk and chunk ~= "" then
    parts[#parts + 1] = chunk
  end

  if not eof then return end

  local raw_body = table.concat(parts)
  kong.ctx.plugin.body_parts = nil

  local looks_gzip = #raw_body >= 2 and raw_body:byte(1) == 0x1f and raw_body:byte(2) == 0x8b
  if kong.ctx.plugin.is_gzip or looks_gzip then
    local ok, inflated = pcall(kong_gzip.inflate_gzip, raw_body)
    if ok and inflated and #inflated > 0 then
      raw_body = inflated
    else
      ngx.log(ngx.WARN, LOG_PREFIX, " gzip inflate failed, falling back to raw body")
    end
  end
  kong.ctx.plugin.body_buf = raw_body

  local app_response = ""
  local has_tool_calls = false

  if conf.ai_proxy_advanced_compat and kong.ctx.plugin.is_sse then
    local content, tool_calls = helpers.parse_sse_buffer(kong.ctx.plugin.body_buf)
    app_response = content
    has_tool_calls = tool_calls ~= nil
    kong.ctx.plugin.streamed_tool_calls = tool_calls
  else
    local resp = cjson.decode(kong.ctx.plugin.body_buf)
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
    end
  end

  kong.ctx.plugin.app_response = app_response
  kong.ctx.plugin.has_tool_calls = has_tool_calls
end

------------------------------------------------------------
-- log (post-call)
------------------------------------------------------------

function StraikerHandler:log(conf)
  if conf.mode == "pre_call" then return end
  if not kong.ctx.plugin.prompt then return end
  if kong.ctx.plugin.blocked then return end
  if kong.ctx.plugin.app_response == nil or kong.ctx.plugin.app_response == "" then return end

  if conf.agentic and kong.ctx.plugin.has_tool_calls then
    return
  end

  local payload = helpers.build_payload({
    conf = conf,
    prompt = kong.ctx.plugin.prompt,
    app_response = kong.ctx.plugin.app_response,
    model = kong.ctx.plugin.model,
    headers = kong.ctx.plugin.headers or {},
    body = kong.ctx.plugin.body,
    messages = kong.ctx.plugin.messages,
    tools = kong.ctx.plugin.tools,
    hook = "post_call",
    dynamic_source = kong.ctx.plugin.dynamic_source,
    model_provider = kong.ctx.plugin.model_provider,
    model_id = kong.ctx.plugin.model_id,
  }, LOG_PREFIX)

  local ok, err = ngx.timer.at(0, function(premature, conf_copy, payload_copy)
    if premature then return end
    local res, terr = call_straiker(conf_copy, payload_copy)
    if not res then
      ngx.log(ngx.ERR, LOG_PREFIX, " post-call failed: ", terr)
      return
    end
    if res.status ~= 200 then
      ngx.log(ngx.ERR, LOG_PREFIX, " post-call non-200: ", res.status, " body: ", res.body)
      return
    end
    local result = cjson.decode(res.body) or {}
    ngx.log(ngx.NOTICE, LOG_PREFIX, " post-call score=", tostring(result.score), " turn_id=", (result.turn_id or result.turnId or "n/a"))
  end, conf, payload)

  if not ok then
    kong.log.err(LOG_PREFIX, " could not schedule post-call timer: ", err)
  end
end

return StraikerHandler
