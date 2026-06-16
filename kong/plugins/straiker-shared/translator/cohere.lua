local Model = require("kong.plugins.straiker-shared.translator.model")
local OpenAiTranslator = require("kong.plugins.straiker-shared.translator.openai")

local function prepare_messages_from_llm_response(response)
  if type(response) ~= "table" then
    return nil, "Invalid response object"
  end

  local messages = response.message
  if messages == nil or type(messages) ~= "table" then
    return nil, "Invalid response object"
  end

  local ret = Model.NewJSONMessageMap()

  local role = messages.role
  for idx, content in ipairs(messages.content) do
    if content.type == "text" then
      ret:add_message(content.text, role, { "message", "content", idx, "text" })
    end
  end

  return ret
end

local CohereTranslator = {
  ["/v2/chat"] = {
    ["request"] = OpenAiTranslator["/v1/chat/completions"].request,
    ["response"] = prepare_messages_from_llm_response,
  },
}

return CohereTranslator
