local translate = {}

function translate.list_available_translators()
  return {
    "anthropic",
    "azureai",
    "bedrock",
    "cohere",
    "gemini",
    "kong",
    "openai",
  }
end

function translate.rewrite_llm_message(original, message_mapping, new_messages)
  local updated = false
  if not new_messages then
    return original, updated
  end

  for idx, prompt_message in ipairs(new_messages) do
    local this_message_lookup = message_mapping.lookup[idx]
    if this_message_lookup == nil then
    else
      local content = original

      local last_part = table.remove(this_message_lookup)
      for _, part in ipairs(this_message_lookup) do
        content = content[part]
      end
      if content[last_part] ~= prompt_message.content then
        content[last_part] = prompt_message.content
        updated = true
      end
    end
  end

  return original, updated
end

function translate.get_translator(provider)
  local ok, translator = pcall(require, "kong.plugins.straiker-shared.translator." .. provider)
  if not ok then
    return nil, "Unknown translator '" .. provider .. "'"
  end

  return translator
end

return translate
