local Model = require("kong.plugins.straiker-shared.translator.model")

local function convert_tools(anthropic_tools)
  local tools = {}
  for _, tool in ipairs(anthropic_tools) do
    if type(tool) == "table" and type(tool.name) == "string" then
      table.insert(tools, {
        type = "function",
        ["function"] = {
          name = tool.name,
          description = tool.description,
          parameters = tool.input_schema,
        },
      })
    end
  end
  return tools
end

local function add_content_part(ret, part, role, idx, jdx)
  if part.type == "text" and type(part.text) == "string" then
    ret:add_message(part.text, role, { "messages", idx, "content", jdx, "text" })

  elseif part.type == "tool_result" then
    local tool_content = part.content
    if type(tool_content) == "string" then
      ret:add_message(tool_content, role, { "messages", idx, "content", jdx, "content" })
    elseif type(tool_content) == "table" then
      for kdx, block in ipairs(tool_content) do
        if block.type == "text" and type(block.text) == "string" then
          ret:add_message(block.text, role, { "messages", idx, "content", jdx, "content", kdx, "text" })
        end
      end
    end
  end
end

local function prepare_messages_request(request)
  if type(request) ~= "table" then
    return nil, "Invalid llm request"
  end

  local ret = Model.NewJSONMessageMap()

  for idx, message in ipairs(request.messages or {}) do
    local role = message.role
    local content = message.content

    if type(content) == "string" then
      ret:add_message(content, role, { "messages", idx, "content" })
    elseif type(content) == "table" then
      for jdx, part in ipairs(content) do
        add_content_part(ret, part, role, idx, jdx)
      end
    end
  end

  return ret
end

local function prepare_messages_response(response)
  if type(response) ~= "table" then
    return nil, "Invalid response object"
  end

  if response.type ~= "message" then
    return nil, "Invalid response object"
  end

  local content = response.content
  if type(content) ~= "table" then
    return nil, "Invalid response object"
  end

  local role = response.role or "assistant"

  local ret = Model.NewJSONMessageMap()
  for idx, part in ipairs(content) do
    if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
      ret:add_message(part.text, role, { "content", idx, "text" })
    end
  end

  return ret
end

return {
  ["/v1/messages"] = {
    ["request"] = function(request)
      local ret, err = prepare_messages_request(request)
      if err ~= nil or ret == nil then
        return ret, err
      end

      local system = request.system
      if system ~= nil then
        if type(system) == "string" then
          ret:add_message(system, "system", { "system" })
        elseif type(system) == "table" then
          for idx, content in ipairs(system) do
            if content.type == "text" then
              ret:add_message(content.text, "system", { "system", idx, "text" }, 1)
            end
          end
        end
      end

      if type(request.tools) == "table" and #request.tools > 0 then
        ret.tools = convert_tools(request.tools)
      end

      return ret
    end,

    ["response"] = prepare_messages_response,
  },
}
