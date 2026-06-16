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

function _M.decode_jwt_claims(headers, log_prefix, debug)
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

function _M.resolve_user_name(headers, body, log_prefix, debug)
  if headers["x-user-name"] then return headers["x-user-name"] end
  local claims = _M.decode_jwt_claims(headers, log_prefix, debug)
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

function _M.block_payload(_, model)
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

function _M.build_webhook_payload(opts, log_prefix)
  local headers = opts.headers or {}
  local debug = opts.conf and opts.conf.debug
  local user_id = _M.resolve_user_name(headers, opts.body, log_prefix, debug)
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

function _M.add_webhook_response(webhook_payload, resp_body, app_response)
  webhook_payload.response = {
    body = resp_body,
    text = app_response,
  }
  return webhook_payload
end

return _M
