local cjson = require "cjson.safe"

-- ============================================================================
-- straiker-saas — Straiker guardrail plugin for Konnect full-SaaS gateways
-- (Dedicated Cloud Gateways), built around Kong's buffered `response` phase.
--
-- WHY A SEPARATE PLUGIN (not a mode of `straiker`):
--   1. Dedicated Cloud runs custom plugins in a sandbox that FORBIDS background
--      timers (ngx.timer.at) and init_worker. The `straiker` plugin does its
--      post-call detection in a log-phase timer (fire-and-forget, streaming-
--      friendly) — not allowed there.
--   2. A Kong plugin cannot implement BOTH `response` AND
--      `body_filter`/`header_filter` (Kong refuses to start). `straiker` uses
--      body_filter to accumulate the response, so the response-phase approach
--      has to be its own plugin.
--
--   This build does everything SYNCHRONOUSLY:
--     access   — input guardrail + blocking, app-source resolution (Entra/OIDC
--                JWT claim), agentic tool-trace capture (request messages[]),
--                and it enables buffered proxying.
--     response — reads the fully-buffered upstream answer, scores it, and can
--                BLOCK / replace it before the client sees it (post-call
--                blocking — a capability the timer build cannot offer).
--   No timers, no body_filter/header_filter, no init_worker, no filesystem
--   writes, no custom-module requires → loads unmodified on Dedicated Cloud as
--   two files (handler.lua + schema.lua).
--
-- TRADEOFF (documented): the `response` phase auto-enables buffered proxying,
-- which holds the whole upstream response before sending → token streaming
-- (stream:true) is buffered and delivered at once, and HTTP/2 / gRPC upstreams
-- are unsupported. Non-streaming JSON is unaffected. Self-hosted / hybrid
-- deployments that need true streaming should use the timer-based `straiker`.
--
-- SANDBOX SAFETY: resty.http and kong.tools.gzip are loaded LAZILY and pcall-
-- guarded (see get_http/get_gzip) so the plugin still loads — and fails open —
-- even if a stricter sandbox blocks the require. The request-body tempfile read
-- is likewise pcall-guarded.
-- ============================================================================

local StraikerSaaS = {
  -- PRIORITY 760 keeps us after ai-proxy / ai-proxy-advanced (PRIORITY 770) in
  -- every phase, so in `response` we read the buffered answer after the AI proxy
  -- has normalized provider-native bytes back into OpenAI chat.completion shape.
  PRIORITY = 760,
  VERSION = "0.8.0",
}

------------------------------------------------------------
-- lazy, sandbox-safe module loaders
------------------------------------------------------------

-- The Dedicated Cloud sandbox restricts `require`. resty.http is fundamental
-- (we have no other way to call the Straiker API), but loading it lazily and
-- pcall-guarded means a blocked require degrades to fail-open instead of a
-- plugin that won't load at all. Cached after first resolution.
local _http_mod
local function get_http()
  if _http_mod == nil then
    local ok, mod = pcall(require, "resty.http")
    _http_mod = ok and mod or false
  end
  return _http_mod or nil
end

-- gzip inflate is only needed if a proxy ignores our Accept-Encoding: identity
-- request (see access). Optional → lazy + guarded; if unavailable we just skip
-- inflation and try to parse the bytes as-is.
local _gzip_mod
local function get_gzip()
  if _gzip_mod == nil then
    local ok, mod = pcall(require, "kong.tools.gzip")
    _gzip_mod = ok and mod or false
  end
  return _gzip_mod or nil
end

------------------------------------------------------------
-- helpers (ported verbatim from the `straiker` handler so the two builds emit
-- identical Straiker payloads — same Console rendering, same agentic schema)
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
  -- OpenAI Chat Completions { id, type, function:{ name, arguments="<json str>" } }
  -- → Straiker agentic { id, name, input=<parsed object> }. Without this reshape
  -- the Console can't render the tool name/arguments.
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
      entry.name = tc.name
      entry.input = tc.input
    end
    table.insert(out, entry)
  end
  return out
end

local function build_agentic_messages(req_messages, app_response, final_tool_calls)
  -- Straiker agentic schema: flat { role, content, tool_calls? } per /detect?agentic.
  -- tool messages also carry tool_call_id + tool_name.
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
    local assistant = { role = "assistant", content = app_response }
    -- If the final upstream turn carried tool_calls (rare on the scored turn,
    -- but possible), include them so the trace's last turn is complete.
    if final_tool_calls then
      assistant.tool_calls = transform_tool_calls(final_tool_calls)
    end
    table.insert(out, assistant)
  end
  return out
end

local function resolve_user_name(headers, body)
  -- Trust order: explicit Straiker header → Kong consumer → OpenAI `user` → fallback.
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

-- resolve_app_source: three-tier per-request app identifier (Entra/Azure AD).
-- Identical to the `straiker` build.
--   Tier 1 — app_id_header: read a pre-injected request header.
--   Tier 2 — jwt_app_claim via kong.ctx.shared.authenticated_jwt_token: the
--            verified JWT left by openid-connect (Entra, validated vs tenant
--            JWKS) or the jwt plugin. Survives ai-proxy-advanced replacing the
--            Authorization header (it is request context, not a header). The
--            production Entra path. EMPIRICALLY VERIFIED against a real tenant.
--   Tier 3 — jwt_app_claim via Authorization: Bearer header (no-auth-plugin
--            fallback; not visible once ai-proxy-advanced replaced the header).
local function resolve_app_source(conf, headers)
  if conf.app_id_header and conf.app_id_header ~= "" and conf.app_id_header ~= "off" then
    local hval = headers and (headers[conf.app_id_header] or headers[conf.app_id_header:lower()])
    if type(hval) == "string" and hval ~= "" then
      return hval
    end
  end

  if not conf.jwt_app_claim or conf.jwt_app_claim == "" or conf.jwt_app_claim == "off" then
    return nil
  end

  -- The auth plugin (openid-connect for Entra, or the jwt plugin) leaves the
  -- verified token here. EMPIRICALLY CONFIRMED: openid-connect populates
  -- kong.ctx.shared.authenticated_jwt_token (and authenticated_token), and it
  -- survives ai-proxy-advanced replacing the Authorization header.
  local raw_token = kong.ctx.shared and kong.ctx.shared.authenticated_jwt_token
  if not raw_token then
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
  if not ok or type(claims) ~= "table" then return nil end

  if conf.jwt_app_claim == "auto" then
    local val = claims.app_displayname or claims.azp or claims.appid
    return type(val) == "string" and val ~= "" and val or nil
  end
  local val = claims[conf.jwt_app_claim]
  return type(val) == "string" and val ~= "" and val or nil
end

local function build_payload(opts)
  -- opts: { conf, prompt, app_response, model, headers, body, messages, hook,
  --         dynamic_source, final_tool_calls }
  local meta = client_metadata(opts.headers, opts.body)
  local trace_id   = opts.headers["x-trace-id"]
  local agent_role = opts.headers["x-agent-role"]
  local effective_source = opts.dynamic_source or opts.conf.source
  local metadata = {
    session_id = meta.session_id,
    user_name  = meta.user_name,
    user_role  = meta.user_role,
    remote_ip  = ngx.var.remote_addr,
    app_name   = effective_source,
    source     = "kong-plugin",
    trace_id   = trace_id,
    agent_role = agent_role,
  }
  if opts.conf.agentic then
    return {
      source = effective_source,
      destination = opts.conf.destination,
      messages = build_agentic_messages(opts.messages, opts.app_response, opts.final_tool_calls),
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
  local http = get_http()
  if not http then
    return nil, "resty.http unavailable (plugin sandbox)"
  end
  local httpc = http.new()
  httpc:set_timeout(conf.timeout)
  local body_json = cjson.encode(payload)
  ngx.log(ngx.DEBUG, "[straiker-saas] sending payload: ", body_json)  -- prompts at DEBUG only
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

-- Parse a buffered SSE response (OpenAI-compatible streaming). Concatenates
-- delta.content across chunks and unions tool_calls indices. Same logic as the
-- `straiker` body_filter accumulator, applied to the whole buffered stream.
local function parse_sse_buffer(buf)
  local content_parts = {}
  local tool_call_acc = {}
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

-- Read the client request body, with a sandbox-safe tempfile fallback for
-- bodies that exceeded client_body_buffer_size (common as agent-loop messages[]
-- grows). Returns the raw string or nil.
local function read_request_body()
  ngx.req.read_body()
  local raw = ngx.req.get_body_data()
  if raw then return raw end
  -- Spilled to a tempfile. The PDK has no in-memory accessor for this case, so
  -- read the file — pcall-guarded because a stricter sandbox may block io.open.
  -- (On Dedicated Cloud, raise client_body_buffer_size so bodies stay in RAM.)
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

-- Emit the configured block response (shared by access pre-call block and
-- response output block). verbose_block → 403; else a safe OpenAI 200.
local function block_payload(conf, model)
  if conf.verbose_block then
    return 403, {
      error = {
        message = "Request blocked by policy.",
        type    = "invalid_request_error",
        code    = "content_policy_violation",
      },
    }
  end
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

------------------------------------------------------------
-- access (pre-call): input guardrail + blocking, app-source, trace capture,
-- and enable buffered proxying so the response phase can read the full answer.
------------------------------------------------------------

function StraikerSaaS:access(conf)
  if conf.mode ~= "pre_call" then
    -- Buffer the upstream response so the `response` phase can read it whole.
    -- (Implementing `response` auto-enables this; calling it here is the
    -- documented, idempotent belt-and-suspenders.)
    kong.service.request.enable_buffering()
    -- Ask the upstream for uncompressed JSON so the response phase can parse it
    -- without inflating. We still inflate defensively if a proxy ignores this.
    kong.service.request.set_header("Accept-Encoding", "identity")
  end

  local raw = read_request_body()
  if not raw or raw == "" then return end

  local body = cjson.decode(raw)
  if not body then return end

  local prompt = last_user_prompt(body.messages)
  if prompt == "" then return end

  -- Stash for the response phase.
  kong.ctx.plugin.prompt = prompt
  kong.ctx.plugin.model = body.model
  kong.ctx.plugin.messages = body.messages
  kong.ctx.plugin.body = body
  kong.ctx.plugin.headers = ngx.req.get_headers()

  -- Per-request app source (Entra/OIDC). On an openid-connect route the verified
  -- token sits in kong.ctx.shared.authenticated_jwt_token (survives
  -- ai-proxy-advanced replacing Authorization). See resolve_app_source.
  local dynamic_source = resolve_app_source(conf, kong.ctx.plugin.headers)
  if dynamic_source then
    kong.ctx.plugin.dynamic_source = dynamic_source
    kong.log.notice("[straiker-saas] app source resolved: ", dynamic_source)
  end

  -- Skip the input guardrail in post_call-only mode unless blocking=true.
  if conf.mode == "post_call" and not conf.blocking then return end

  -- Agent-loop dedupe: skip pre-call on continuation iterations (tool/assistant
  -- last message) unless blocking=true (then score every iteration so poisoned
  -- tool results can be blocked).
  local last_msg = body.messages and body.messages[#body.messages]
  if conf.agentic and not conf.blocking and last_msg
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
    dynamic_source = kong.ctx.plugin.dynamic_source,
  })

  local res, err = call_straiker(conf, payload)

  if not res then
    kong.log.err("[straiker-saas] pre-call failed: ", err)
    if conf.fail_open then return end
    return kong.response.exit(503, {
      error = { message = "Straiker unavailable: " .. tostring(err), code = "503" },
    })
  end

  if res.status ~= 200 then
    kong.log.err("[straiker-saas] pre-call non-200: ", res.status, " body: ", res.body)
    if conf.fail_open then return end
    return kong.response.exit(503, {
      error = { message = "Straiker returned " .. res.status, code = "503" },
    })
  end

  local result = cjson.decode(res.body) or {}
  local score = tonumber(result.score) or 0
  kong.log.notice("[straiker-saas] pre-call score=", score, " turn_id=", (result.turn_id or result.turnId or "n/a"))

  if score > conf.threshold then
    -- Mark blocked so the response phase doesn't score a request that never
    -- reached the upstream model.
    kong.ctx.plugin.blocked = true
    local status, payload_tbl = block_payload(conf, kong.ctx.plugin.model)
    return kong.response.exit(status, payload_tbl)
  end
end

------------------------------------------------------------
-- response (post-call): read the buffered upstream answer, score it
-- synchronously, optionally block/replace it. No timer — cosockets are allowed
-- in this phase. Implementing `response` precludes body_filter/header_filter.
------------------------------------------------------------

function StraikerSaaS:response(conf)
  if conf.mode == "pre_call" then return end
  if not kong.ctx.plugin.prompt then return end
  -- Pre-call already blocked: the upstream never ran, nothing real to score.
  if kong.ctx.plugin.blocked then return end

  local raw_body = kong.service.response.get_raw_body()
  if not raw_body or raw_body == "" then return end

  -- Defensive gzip inflate (we ask for identity in access, but a proxy may
  -- ignore it). We only inflate our local copy for scoring; the client still
  -- receives the original bytes unless we block.
  local looks_gzip = #raw_body >= 2 and raw_body:byte(1) == 0x1f and raw_body:byte(2) == 0x8b
  if looks_gzip then
    local gzip = get_gzip()
    if gzip then
      local ok, inflated = pcall(gzip.inflate_gzip, raw_body)
      if ok and inflated and #inflated > 0 then raw_body = inflated end
    end
  end

  -- Parse: buffered SSE stream or single chat.completion JSON (auto-detected).
  local ct = kong.service.response.get_header("Content-Type") or ""
  local is_sse = ct:find("text/event-stream", 1, true) ~= nil

  local app_response, has_tool_calls, final_tool_calls = "", false, nil
  if is_sse then
    local content, tool_calls = parse_sse_buffer(raw_body)
    app_response = content
    has_tool_calls = tool_calls ~= nil
    final_tool_calls = tool_calls
  else
    local resp = cjson.decode(raw_body)
    if resp and resp.choices and resp.choices[1] and resp.choices[1].message then
      local msg = resp.choices[1].message
      -- cjson.safe decodes JSON null to a sentinel; treat as missing for both
      -- content (avoid leaking "userdata: NULL") and tool_calls (avoid skipping
      -- the final turn when tool_calls is null).
      local content = msg.content
      if content == nil or content == cjson.null or type(content) ~= "string" then
        app_response = ""
      else
        app_response = content
      end
      local tcs = msg.tool_calls
      has_tool_calls = type(tcs) == "table" and #tcs > 0
      if has_tool_calls then final_tool_calls = tcs end
    end
  end

  -- Agentic dedupe: skip intermediate tool-calling turns; only score the final
  -- assistant turn (whose request messages[] carries the full trace). The
  -- response is forwarded unchanged either way.
  if conf.agentic and has_tool_calls then return end
  if app_response == "" then return end

  local payload = build_payload({
    conf = conf,
    prompt = kong.ctx.plugin.prompt,
    app_response = app_response,
    model = kong.ctx.plugin.model,
    headers = kong.ctx.plugin.headers or {},
    body = kong.ctx.plugin.body,
    messages = kong.ctx.plugin.messages,
    hook = "post_call",
    dynamic_source = kong.ctx.plugin.dynamic_source,
    final_tool_calls = final_tool_calls,
  })

  local res, err = call_straiker(conf, payload)
  if not res then
    kong.log.err("[straiker-saas] response-eval failed: ", err)
    return  -- fail-open: never withhold a real answer because the scorer was down
  end
  if res.status ~= 200 then
    kong.log.err("[straiker-saas] response-eval non-200: ", res.status, " body: ", res.body)
    return
  end

  local result = cjson.decode(res.body) or {}
  local score = tonumber(result.score) or 0
  kong.log.notice("[straiker-saas] response-eval score=", score, " turn_id=", (result.turn_id or result.turnId or "n/a"))

  if conf.block_response and score > conf.threshold then
    kong.log.notice("[straiker-saas] BLOCKING response (score=", score, " > ", conf.threshold, ")")
    local status, payload_tbl = block_payload(conf, kong.ctx.plugin.model)
    -- Replace the buffered answer before it reaches the client. kong.response.exit
    -- short-circuits cleanly in the response phase; note that calling
    -- kong.response.set_raw_body here instead crashes the worker when
    -- ai-proxy-advanced is on the route (it post-processes the buffered body and
    -- the two writers collide), whereas exit() produces the final response and
    -- halts further processing.
    return kong.response.exit(status, payload_tbl)
  end
  -- Not blocking → return without mutating; Kong forwards the original answer.
end

return StraikerSaaS
