local Model = require("kong.plugins.straiker-shared.translator.model")

local function convert_tools(gemini_tools)
  local tools = {}
  for _, tool_group in ipairs(gemini_tools) do
    local decls = type(tool_group) == "table" and tool_group.functionDeclarations
    if type(decls) == "table" then
      for _, decl in ipairs(decls) do
        if type(decl) == "table" and type(decl.name) == "string" then
          table.insert(tools, {
            type = "function",
            ["function"] = {
              name = decl.name,
              description = decl.description,
              parameters = decl.parameters,
            },
          })
        end
      end
    end
  end
  return tools
end

local role_transform = {
  ["model"] = Model.AidrRoles.PromptRoleLlm,
}
setmetatable(role_transform, {
  __index = function(_, val)
    return val
  end,
})

local function prepare_chat_completions_request(request)
  if type(request) ~= "table" then
    return nil, "Invalid llm request"
  end

  local ret = Model.NewJSONMessageMap()

  local system = request.system_instructions
  if system ~= nil then
    for idx, part in ipairs(system.parts) do
      local text = part.text
      if text ~= nil then
        ret:add_message(text, "system", { "system_instructions", "parts", idx, "text" })
      end
    end
  end

  for idx, content in ipairs(request.contents) do
    local role = role_transform[content.role]
    for jdx, part in ipairs(content.parts) do
      local text = part.text
      if text ~= nil then
        ret:add_message(text, role, { "contents", idx, "parts", jdx, "text" })
      end
    end
  end

  if type(request.tools) == "table" and #request.tools > 0 then
    local tools = convert_tools(request.tools)
    if #tools > 0 then
      ret.tools = tools
    end
  end

  return ret
end

local function prepare_chat_completions_response(response)
  if type(response) ~= "table" then
    return nil, "Invalid llm request"
  end

  local ret = Model.NewJSONMessageMap()

  for idx, candidate in ipairs(response.candidates) do
    for jdx, content in ipairs(candidate.content) do
      local role = role_transform[content.role] or Model.AidrRoles.PromptRoleLlm
      for kdx, part in ipairs(content.parts) do
        local text = part.text
        if text ~= nil then
          ret:add_message(text, role, { "candidates", idx, "content", jdx, "parts", kdx, "text" })
        end
      end
    end
  end

  return ret
end

return {
  ["/v1/models"] = {
    ["request"] = prepare_chat_completions_request,
    ["response"] = prepare_chat_completions_response,
  },
  ["generateContent"] = {
    ["request"] = prepare_chat_completions_request,
    ["response"] = prepare_chat_completions_response,
  },
}
