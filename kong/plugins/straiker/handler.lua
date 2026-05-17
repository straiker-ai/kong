local http = require "resty.http"
local cjson = require "cjson.safe"
local kong_gzip = require "kong.tools.gzip"

-- PRIORITY 760 puts us after Kong's ai-proxy / ai-proxy-advanced (PRIORITY 770)
-- in body_filter, so we read the upstream response *after* ai-proxy-advanced
-- has normalized provider-native bytes (Bedrock/Anthropic/etc.) back into the
-- OpenAI chat.completion shape. We still see the original client request in
-- access via ngx.req.get_body_data() because Kong preserves the client body
-- buffer even when ai-proxy-advanced rewrites the upstream request via
-- kong.service.request.set_raw_body.
local StraikerHandler = {
  PRIORITY = 760,
  VERSION = "0.4.0",
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
  ngx.log(ngx.DEBUG, "[straiker] sending payload: ", body_json)
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
  if not raw then
    -- Kong buffered the body to a tempfile because it exceeded
    -- client_body_buffer_size (default 8 KiB). Common with agent-loop
    -- iterations where messages[] accumulates tool results. Pull it back.
    local body_file = ngx.req.get_body_file()
    if body_file then
      local f = io.open(body_file, "rb")
      if f then
        raw = f:read("*a")
        f:close()
      end
    end
  end
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

  -- Agent-loop dedupe: in agentic mode, skip pre-call only on continuation
  -- iterations of the agent loop (last message is a tool result or an
  -- intermediate assistant turn). Pre-call STILL fires on the first iteration
  -- where the last message is real user input -- that's the right point to
  -- block obviously bad prompts before the agent starts working. This keeps
  -- gateway-level blocking working for agentic routes without producing the
  -- empty-response duplicate turns we'd see if pre-call ran every iteration.
  local last_msg = body.messages and body.messages[#body.messages]
  if conf.agentic and last_msg
     and (last_msg.role == "tool" or last_msg.role == "assistant") then
    return
  end

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
    -- Mark the request as blocked so the log phase skips post-call detection.
    -- Without this flag, body_filter buffers the 403 error JSON we're about
    -- to emit, sets app_response to "" (which is truthy in Lua), and the log
    -- phase fires a phantom post-call turn for a request that never reached
    -- the upstream model.
    kong.ctx.plugin.blocked = true
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
  -- Remember the response Content-Type / Encoding so body_filter knows whether
  -- to parse the buffer as a single chat.completion JSON, an SSE stream, and
  -- whether the buffer is gzipped. ai-proxy-advanced does not honor our
  -- access-phase Accept-Encoding: identity override and forwards OpenAI's
  -- gzipped bytes unchanged when the upstream chose gzip — so we must inflate
  -- before parsing.
  local ct = ngx.header.content_type or ""
  kong.ctx.plugin.is_sse = ct:find("text/event-stream", 1, true) ~= nil
  local ce = ngx.header.content_encoding or ""
  kong.ctx.plugin.is_gzip = ce:lower():find("gzip", 1, true) ~= nil
end

-- Parse a buffered SSE response from ai-proxy-advanced (or any
-- OpenAI-compatible streaming upstream). Concatenates delta.content across
-- all chunks and unions tool_calls indices into a flat list. Returns
-- (assembled_text, tool_calls_or_nil).
local function parse_sse_buffer(buf)
  local content_parts = {}
  local tool_call_acc = {}  -- index -> { id, function = { name, arguments } }
  local saw_tool_calls = false

  for line in buf:gmatch("[^\r\n]+") do
    local data = line:match("^data:%s*(.+)$")
    if data and data ~= "[DONE]" then
      local ok, evt = pcall(cjson.decode, data)
      if ok and type(evt) == "table" and evt.choices and evt.choices[1] then
        local delta = evt.choices[1].delta or evt.choices[1].message
        if delta then
          if type(delta.content) == "string" and delta.content ~= "" then
            table.insert(content_parts, delta.content)
          end
          if type(delta.tool_calls) == "table" then
            saw_tool_calls = true
            for _, tc in ipairs(delta.tool_calls) do
              local idx = tc.index or (#tool_call_acc + 1)
              local slot = tool_call_acc[idx] or { ["function"] = { arguments = "" } }
              if tc.id then slot.id = tc.id end
              if tc.type then slot.type = tc.type end
              if tc["function"] then
                if tc["function"].name then slot["function"].name = tc["function"].name end
                if tc["function"].arguments then
                  slot["function"].arguments = (slot["function"].arguments or "") .. tc["function"].arguments
                end
              end
              tool_call_acc[idx] = slot
            end
          end
        end
      end
    end
  end

  local tool_calls = nil
  if saw_tool_calls then
    tool_calls = {}
    -- Collect indices and sort: OpenAI typically emits contiguous indices
    -- starting at 0, but be defensive against gaps or non-zero start.
    local indices = {}
    for idx in pairs(tool_call_acc) do
      indices[#indices + 1] = idx
    end
    table.sort(indices)
    for _, idx in ipairs(indices) do
      tool_calls[#tool_calls + 1] = tool_call_acc[idx]
    end
  end
  return table.concat(content_parts), tool_calls
end

function StraikerHandler:body_filter(conf)
  if conf.mode == "pre_call" then return end
  if not kong.ctx.plugin.prompt then return end

  local chunk = ngx.arg[1]
  local eof = ngx.arg[2]
  -- Accumulate chunks in a table and concat at EOF (O(n)). Repeated string
  -- concatenation in Lua is O(n^2) and noticeable on multi-MB streams.
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
  -- Free the per-chunk table now that we have the assembled body.
  kong.ctx.plugin.body_parts = nil

  -- Inflate gzipped responses before parsing. Detected via header_filter.
  -- Defensive check on magic bytes too for cases where the header was missing.
  local looks_gzip = #raw_body >= 2 and raw_body:byte(1) == 0x1f and raw_body:byte(2) == 0x8b
  if kong.ctx.plugin.is_gzip or looks_gzip then
    local ok, inflated = pcall(kong_gzip.inflate_gzip, raw_body)
    if ok and inflated and #inflated > 0 then
      raw_body = inflated
    else
      ngx.log(ngx.WARN, "[straiker] gzip inflate failed, falling back to raw body")
    end
  end
  kong.ctx.plugin.body_buf = raw_body

  local app_response = ""
  local has_tool_calls = false

  if conf.ai_proxy_advanced_compat and kong.ctx.plugin.is_sse then
    -- Streaming path: accumulate delta.content across SSE events.
    local content, tool_calls = parse_sse_buffer(kong.ctx.plugin.body_buf)
    app_response = content
    has_tool_calls = tool_calls ~= nil
    -- Preserve the parsed tool_calls so the agentic post-call payload includes
    -- them in the assistant turn. Used by build_agentic_messages below.
    kong.ctx.plugin.streamed_tool_calls = tool_calls
  else
    -- Single-shot JSON path (v0.3.x behavior).
    local resp = cjson.decode(kong.ctx.plugin.body_buf)
    if resp and resp.choices and resp.choices[1] and resp.choices[1].message then
      local msg = resp.choices[1].message
      -- cjson.safe decodes JSON `null` to a non-nil sentinel (cjson.null). Treat
      -- it as missing both for content (otherwise the literal "userdata: NULL"
      -- would leak into app_response) and for tool_calls (otherwise we'd flag
      -- final-iteration responses with tool_calls:null as "still calling tools"
      -- and skip post-call — silently dropping every agent-loop final turn).
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
-- log (post-call): fire-and-forget detection on prompt + response
------------------------------------------------------------

function StraikerHandler:log(conf)
  if conf.mode == "pre_call" then return end
  if not kong.ctx.plugin.prompt then return end
  -- Skip post-call detection on requests blocked at pre-call. The upstream
  -- never ran, so there is no real response to score; firing post-call here
  -- would create a phantom Console turn with empty content.
  if kong.ctx.plugin.blocked then return end
  if kong.ctx.plugin.app_response == nil or kong.ctx.plugin.app_response == "" then return end

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
