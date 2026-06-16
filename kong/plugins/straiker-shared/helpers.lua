local cjson = require "cjson.safe"

local _M = {}

function _M.extract_text_content(content)
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

function _M.last_user_prompt(messages)
  if type(messages) ~= "table" then return "" end
  for i = #messages, 1, -1 do
    local m = messages[i]
    if m and m.role == "user" then
      return _M.extract_text_content(m.content)
    end
  end
  return ""
end

function _M.transform_tool_calls(tcs)
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

function _M.build_agentic_messages(req_messages, app_response, final_tool_calls, tools)
  local out = {}
  if type(req_messages) == "table" then
    for _, m in ipairs(req_messages) do
      local entry = { role = m.role, content = m.content or "" }
      if m.tool_calls then entry.tool_calls = m.tool_calls end
      if m.tool_call_id then entry.tool_call_id = m.tool_call_id end
      if m.name then entry.name = m.name end
      if m.role == "system" and type(tools) == "table" and #tools > 0 then
        entry.functions = tools
      end
      table.insert(out, entry)
    end
  end
  if app_response and app_response ~= "" and app_response ~= "N/A" then
    local assistant = { role = "assistant", content = app_response }
    if final_tool_calls then assistant.tool_calls = final_tool_calls end
    table.insert(out, assistant)
  end
  return out
end

function _M.decode_jwt_claims(headers, log_prefix)
  local raw_token = kong.ctx.shared and kong.ctx.shared.authenticated_jwt_token
  if raw_token then
    kong.log.debug(log_prefix, " authenticated_jwt_token found in kong.ctx.shared")
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

function _M.resolve_ai_model_info()
  local ai_ctx = ngx.ctx.ai_namespaced_ctx
  if not ai_ctx then return nil, nil end
  local nr = ai_ctx["normalize-request"]
  local provider = nr and nr.model and nr.model.provider
  local model_name = nr and nr.model and nr.model.name
  return provider, model_name
end

function _M.resolve_user_name(headers, body, log_prefix)
  if headers["x-user-name"] then return headers["x-user-name"] end
  local claims = _M.decode_jwt_claims(headers, log_prefix)
  if claims then
    local user = claims.email or claims.preferred_username
                 or claims["cognito:username"] or claims.sub
    if type(user) == "string" and user ~= "" then
      kong.log.debug(log_prefix, " user from JWT: ", user)
      return user
    end
  end
  if body and type(body.user) == "string" and body.user ~= "" then
    return body.user
  end
  return "kong"
end

function _M.client_metadata(headers, body, log_prefix)
  return {
    user_name = _M.resolve_user_name(headers, body, log_prefix),
    user_role = headers["x-user-role"] or "public",
    session_id = headers["x-session-id"] or ngx.var.request_id or "kong-session",
    network = {
      IP = ngx.var.remote_addr or "127.0.0.1",
      ["User-Agent"] = headers["user-agent"] or "kong",
      ["Content-Type"] = "application/json",
    },
  }
end

function _M.resolve_app_source(conf, headers, log_prefix)
  if conf.app_id_header and conf.app_id_header ~= "" and conf.app_id_header ~= "off" then
    local hval = headers and (headers[conf.app_id_header] or headers[conf.app_id_header:lower()])
    if type(hval) == "string" and hval ~= "" then
      return hval
    end
  end

  local ok, consumer = pcall(function() return kong.client.get_consumer() end)
  if ok and consumer then
    kong.log.debug(log_prefix, " consumer found: username=", consumer.username, " custom_id=", consumer.custom_id)
    if consumer.username or consumer.custom_id then
      return consumer.username or consumer.custom_id
    end
  else
    kong.log.debug(log_prefix, " no consumer on this request")
  end

  return nil
end

function _M.build_payload(opts, log_prefix)
  local meta = _M.client_metadata(opts.headers, opts.body, log_prefix)
  local trace_id   = opts.headers["x-trace-id"]
  local agent_role = opts.headers["x-agent-role"]
  local effective_source = opts.dynamic_source or opts.conf.source or "Kong Default App"
  local metadata = {
    session_id     = meta.session_id,
    user_name      = meta.user_name,
    user_role      = meta.user_role,
    remote_ip      = ngx.var.remote_addr,
    app_name       = effective_source,
    source         = "kong-plugin",
    trace_id       = trace_id,
    agent_role     = agent_role,
    model_provider = opts.model_provider,
    model_id       = opts.model_id,
  }
  if opts.conf.agentic then
    return {
      source = effective_source,
      destination = opts.conf.destination,
      messages = _M.build_agentic_messages(opts.messages, opts.app_response, opts.final_tool_calls, opts.tools),
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

function _M.detect_url(conf)
  if conf.agentic then
    if conf.detect_url:find("?", 1, true) then
      return conf.detect_url .. "&agentic"
    else
      return conf.detect_url .. "?agentic"
    end
  end
  return conf.detect_url
end

function _M.parse_sse_buffer(buf)
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

function _M.block_payload(conf, model)
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

function _M.read_original_body()
  local ai_ctx = ngx.ctx.ai_namespaced_ctx
  if ai_ctx and ai_ctx._global and type(ai_ctx._global.request_body) == "string" then
    local raw = ai_ctx._global.request_body
    if raw ~= "" then return raw, true end
  end
  return nil, false
end

return _M
