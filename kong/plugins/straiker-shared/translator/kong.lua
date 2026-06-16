local OpenAiTranslator    = require("kong.plugins.straiker-shared.translator.openai")
local AnthropicTranslator = require("kong.plugins.straiker-shared.translator.anthropic")
local BedrockTranslator   = require("kong.plugins.straiker-shared.translator.bedrock")

local function detect_and_parse_response(response)
  if type(response) ~= "table" then
    return nil, "Invalid response object"
  end

  if response.object == "chat.completion" then
    return OpenAiTranslator["/v1/chat/completions"].response(response)
  end

  if response.object == "text_completion" then
    return OpenAiTranslator["/v1/completions"].response(response)
  end

  if response.type == "message" then
    return AnthropicTranslator["/v1/messages"].response(response)
  end

  if type(response.output) == "table" and type(response.output.message) == "table" then
    return BedrockTranslator["converse"].response(response)
  end

  return nil, "Unrecognized response format from Kong AI Proxy"
end

local KongAIProxyTranslator = {
  ["/llm/v1/chat"] = {
    ["request"]  = OpenAiTranslator["/v1/chat/completions"].request,
    ["response"] = detect_and_parse_response,
  },
  ["/llm/v1/completions"] = {
    ["request"]  = OpenAiTranslator["/v1/completions"].request,
    ["response"] = OpenAiTranslator["/v1/completions"].response,
  },
}

return KongAIProxyTranslator
