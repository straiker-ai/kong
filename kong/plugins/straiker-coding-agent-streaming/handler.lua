-- Straiker Defend coding-agent detection — STREAMING variant.
--
-- Attach to interactive developer routes. Responses stream to the client
-- untouched. Prompt inspection and IPI (poisoned tool results on the next
-- request) are enforced; a tool_use cannot be suppressed before the client
-- runs it — that is the buffered plugin.
--
-- Never attach both coding-agent plugins to the same route.

local core = require "kong.plugins.straiker.coding_agent"

local StraikerCodingAgentStreaming = {
  -- Above ai-proxy (770) so get_raw_body() is the untranslated client body.
  -- Below Kong auth (key-auth 1250, jwt 1450) so the consumer is resolved.
  PRIORITY = 1000,
  VERSION  = "0.11.0",
}


function StraikerCodingAgentStreaming:access(conf)
  core.access(conf)
end


function StraikerCodingAgentStreaming:body_filter(conf)
  core.accumulate(conf)
end


function StraikerCodingAgentStreaming:log(conf)
  core.relay(conf)
end


return StraikerCodingAgentStreaming
