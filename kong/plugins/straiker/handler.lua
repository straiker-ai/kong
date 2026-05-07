local http = require "resty.http"
local cjson = require "cjson.safe"

local StraikerHandler = {
  PRIORITY = 950,
  VERSION = "0.3.0",
}

------------------------------------------------------------
-- helpers
------------------------------------------------------------

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

local function transform_tool_calls(tcs)
  -- OpenAI Chat Completions format:
  --   { id, type, function: { name, arguments = "<stringified JSON>" } }
  -- Straiker agentic schema (per /api/v1/detect?agentic):
  --   { id, name, input = <parsed object> }
  -- Without this reshape, the Console can't render the tool name or arguments
  -- because it looks up `name` and `input` directly on each tool_call entry.
  if type(tcs) ~= "table" then return nil end
  local out = {}
  for _, tc in ipairs(tcs) do
    local entry = { id = tc.id }
    if type(tc.func) == "table" or type(tc["function"]) == "table" then
      local fn = tc["function"] or tc.func
      entry.name = fn.name
      if type(fn.arguments) == "string" then
        local ok, parsed = pcall(cjson.decode, fn.arguments)
        entry.input = ok and parsed or { _raw = fn.arguments }
      elseif type(fn.arguments) == "table" then
        entry.input = fn.arguments
      end
    else
      -- already flat (Straiker shape passed through from a prior turn)
      entry.name = tc.name
      entry.input = tc.input
    end
    table.insert(out, entry)
  end
  return out
end

local function build_agentic_messages(req_messages, app_response)
  -- Straiker agentic schema: flat { role, content, tool_calls? } per the
  -- /api/v1/detect?agentic API. tool messages additionally carry
  -- tool_call_id and tool_name.
  local out = {}
  if type(req_messages) == "table" then
    for _, m in ipairs(req_messages) do
      local entry = { role = m.role }
      local content = extract_text_content(m.content)
      if content ~= "" then
        entry.content = content
      end
      if m.tool_calls then
        entry.tool_calls = transform_tool_calls(m.tool_calls)
      end
      if m.tool_call_id then
        entry.tool_call_id = m.tool_call_id
      end
      if m.name then
        entry.tool_name = m.name
      elseif m.tool_name then
        entry.tool_name = m.tool_name
      end
      table.insert(out, entry)
    end
  end
  if app_response and app_response ~= "" and app_response ~= "N/A" then
    table.insert(out, {
      role = "assistant",
      content = app_response,
    })
  end
  return out
end

local function resolve_user_name(headers, body)
  -- Identity fallback chain, in order of trust:
  --   1. Explicit Straiker header set by upstream identity gateway
  --   2. Kong consumer (set by kong key-auth/jwt/oauth plugins)
  --   3. OpenAI standard `user` field in the request body
  --   4. fallback
  if headers["x-user-name"] then return headers["x-user-name"] end
  local ok, consumer = pcall(function() return kong.client.get_consumer() end)
  if ok and consumer and (consumer.username or consumer.custom_id) then
    return consumer.username or consumer.custom_id
  end
  if body and type(body.user) == "string" and body.user ~= "" then
    return body.user
  end
  return "kong"
end

local function client_metadata(headers, body)
  return {
    user_name = resolve_user_name(headers, body),
    user_role = headers["x-user-role"] or "public",
    session_id = headers["x-session-id"] or ngx.var.request_id or "kong-session",
    network = {
      IP = ngx.var.remote_addr or "127.0.0.1",
      ["User-Agent"] = headers["user-agent"] or "kong",
      ["Content-Type"] = "application/json",
    },
  }
end

local function build_payload(opts)
  -- opts: { conf, prompt, app_response, model, headers, body, messages }
  local meta = client_metadata(opts.headers, opts.body)
  local trace_id   = opts.headers["x-trace-id"]
  local agent_role = opts.headers["x-agent-role"]
  -- /detect?agentic schema: identity travels in a metadata{} envelope. Field
  -- names match the working /detect payload Argus expects (user_name,
  -- session_id, user_role, remote_ip). trace_id and agent_role ride along so
  -- a multi-agent / multi-model interaction can be stitched into one trace.
  local metadata = {
    session_id = meta.session_id,
    user_name  = meta.user_name,
    user_role  = meta.user_role,
    remote_ip  = ngx.var.remote_addr,
    app_name   = opts.conf.source,
    source     = "kong-plugin",
    trace_id   = trace_id,
    agent_role = agent_role,
  }
  if opts.conf.agentic then
    return {
      source = opts.conf.source,
      destination = opts.conf.destination,
      messages = build_agentic_messages(opts.messages, opts.app_response),
      session_id = meta.session_id,
      user_name = meta.user_name,
      user_role = meta.user_role,
      metadata = metadata,
      network = meta.network,
      annotations = {
        source = "kong-plugin",
        model = opts.model or "unknown",
        hook = opts.hook,
        trace_id = trace_id,
        agent_role = agent_role,
      },
    }
  end
  return {
    prompt = opts.prompt,
    app_response = opts.app_response or "N/A",
    rag_content = "N/A",
    session_id = meta.session_id,
    user_name = meta.user_name,
    user_role = meta.user_role,
    metadata = metadata,
    network = meta.network,
    annotations = {
      source = "kong-plugin",
      model = opts.model or "unknown",
      hook = opts.hook,
      trace_id = trace_id,
      agent_role = agent_role,
    },
  }
end

local function detect_url(conf)
  if conf.agentic then
    if conf.detect_url:find("?", 1, true) then
      return conf.detect_url .. "&agentic"
    else
      return conf.detect_url .. "?agentic"
    end
  end
  return conf.detect_url
end

local function call_straiker(conf, payload)
  local httpc = http.new()
  httpc:set_timeout(conf.timeout)
  local body_json = cjson.encode(payload)
  -- payload includes user prompts; logged at DEBUG only
  ngx.log(ngx.NOTICE, "[straiker] sending payload: ", body_json)
  local res, err = httpc:request_uri(detect_url(conf), {
    method = "POST",
    body = body_json,
    headers = {
      ["Authorization"] = "Bearer " .. conf.api_key,
      ["Content-Type"] = "application/json",
    },
    ssl_verify = true,
    keepalive_timeout = 60000,
    keepalive_pool = 10,
  })
  return res, err
end

------------------------------------------------------------
-- access (pre-call): block before reaching upstream
------------------------------------------------------------

function StraikerHandler:access(conf)
  -- Force upstream to return uncompressed JSON so body_filter can parse it.
  -- Without this OpenAI may return Content-Encoding: gzip/br and the post-call
  -- response capture silently fails.
  if conf.mode ~= "pre_call" then
    ngx.req.set_header("Accept-Encoding", "identity")
  end

  ngx.req.read_body()
  local raw = ngx.req.get_body_data()
  if not raw or raw == "" then return end

  local body = cjson.decode(raw)
  if not body then return end

  local prompt = last_user_prompt(body.messages)
  if prompt == "" then return end

  -- stash for post-call hook
  kong.ctx.plugin.prompt = prompt
  kong.ctx.plugin.model = body.model
  kong.ctx.plugin.messages = body.messages
  kong.ctx.plugin.body = body
  kong.ctx.plugin.headers = ngx.req.get_headers()

  if conf.mode == "post_call" then return end

  -- Agentic apps: skip pre-call entirely. The agent loop runs server-side
  -- and the post-call payload carries the full conversation (system, user,
  -- assistant tool_calls, tool results, final assistant message), so a
  -- pre-call hook produces an empty-response duplicate turn in the Console
  -- without protecting anything new. Standard chatbot routes (agentic=false)
  -- still get pre-call gating for inline blocking.
  if conf.agentic then return end

  local payload = build_payload({
    conf = conf,
    prompt = prompt,
    app_response = "N/A",
    model = body.model,
    headers = kong.ctx.plugin.headers,
    body = body,
    messages = body.messages,
    hook = "pre_call",
  })

  local res, err = call_straiker(conf, payload)

  if not res then
    kong.log.err("[straiker] pre-call failed: ", err)
    if conf.fail_open then return end
    return kong.response.exit(503, {
      error = { message = "Straiker unavailable: " .. tostring(err), code = "503" },
    })
  end

  if res.status ~= 200 then
    kong.log.err("[straiker] pre-call non-200: ", res.status, " body: ", res.body)
    if conf.fail_open then return end
    return kong.response.exit(503, {
      error = { message = "Straiker returned " .. res.status, code = "503" },
    })
  end

  local result = cjson.decode(res.body) or {}
  local score = tonumber(result.score) or 0
  kong.log.notice("[straiker] pre-call score=", score, " turn_id=", (result.turn_id or result.turnId or "n/a"))

  if score > conf.threshold then
    return kong.response.exit(403, {
      error = {
        message = "Straiker: threat detected (pre-call)",
        score = score,
        turn_id = result.turn_id or result.turnId,
        code = "403",
      },
    })
  end
end

------------------------------------------------------------
-- header_filter / body_filter: capture upstream response
------------------------------------------------------------

function StraikerHandler:header_filter(conf)
  if conf.mode == "pre_call" then return end
  -- swallow Content-Length so the buffered body can be re-emitted unchanged
  ngx.header.content_length = nil
end

function StraikerHandler:body_filter(conf)
  if conf.mode == "pre_call" then return end
  if not kong.ctx.plugin.prompt then return end

  local chunk = ngx.arg[1]
  local eof = ngx.arg[2]
  kong.ctx.plugin.body_buf = (kong.ctx.plugin.body_buf or "") .. (chunk or "")

  if eof then
    local resp = cjson.decode(kong.ctx.plugin.body_buf)
    local app_response = ""
    local has_tool_calls = false
    if resp and resp.choices and resp.choices[1] and resp.choices[1].message then
      app_response = resp.choices[1].message.content or ""
      has_tool_calls = resp.choices[1].message.tool_calls ~= nil
    end
    kong.ctx.plugin.app_response = app_response
    kong.ctx.plugin.has_tool_calls = has_tool_calls
  end
end

------------------------------------------------------------
-- log (post-call): fire-and-forget detection on prompt + response
------------------------------------------------------------

function StraikerHandler:log(conf)
  if conf.mode == "pre_call" then return end
  if not kong.ctx.plugin.prompt then return end
  if not kong.ctx.plugin.app_response then return end

  -- Agent-loop dedupe: in agentic mode, skip post-call detection on any
  -- iteration where the model still wants to call a tool. Only fire on the
  -- iteration that returns a final assistant message with no tool_calls --
  -- that turn's messages[] carries the full conversation, including all
  -- prior tool calls and their results, so one post-call captures everything.
  if conf.agentic and kong.ctx.plugin.has_tool_calls then
    return
  end

  local payload = build_payload({
    conf = conf,
    prompt = kong.ctx.plugin.prompt,
    app_response = kong.ctx.plugin.app_response,
    model = kong.ctx.plugin.model,
    headers = kong.ctx.plugin.headers or {},
    body = kong.ctx.plugin.body,
    messages = kong.ctx.plugin.messages,
    hook = "post_call",
  })

  -- defer into a fresh ngx.timer so cosockets are allowed
  local ok, err = ngx.timer.at(0, function(premature, conf_copy, payload_copy)
    if premature then return end
    local res, terr = call_straiker(conf_copy, payload_copy)
    if not res then
      ngx.log(ngx.ERR, "[straiker] post-call failed: ", terr)
      return
    end
    if res.status ~= 200 then
      ngx.log(ngx.ERR, "[straiker] post-call non-200: ", res.status, " body: ", res.body)
      return
    end
    local result = cjson.decode(res.body) or {}
    ngx.log(ngx.NOTICE, "[straiker] post-call score=", tostring(result.score), " turn_id=", (result.turn_id or result.turnId or "n/a"))
  end, conf, payload)

  if not ok then
    kong.log.err("[straiker] could not schedule post-call timer: ", err)
  end
end

return StraikerHandler
