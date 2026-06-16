local AidrRoles = {
  PromptRoleSystem = "system",
  PromptRoleUser = "user",
  PromptRoleLlm = "assistant",
}

local JSONMessageMap = {
  messages = {},
  lookup = {},
  tools = nil,
}

function JSONMessageMap:add_message(content, role, path, pos)
  if pos ~= nil then
    table.insert(self.messages, pos, {
      content = content,
      role = role,
    })
    table.insert(self.lookup, pos, path)
  else
    table.insert(self.messages, {
      content = content,
      role = role,
    })
    table.insert(self.lookup, path)
  end
end

local function NewJSONMessageMap()
  local self = {
    messages = {},
    lookup = {},
    tools = nil,
  }
  setmetatable(self, { __index = JSONMessageMap })
  return self
end

return {
  AidrRoles = AidrRoles,
  NewJSONMessageMap = NewJSONMessageMap,
}
