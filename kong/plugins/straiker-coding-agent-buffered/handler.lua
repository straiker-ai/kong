-- Straiker Defend coding-agent detection — BUFFERED variant.
--
-- Attach where a tool call must be stopped before it executes (CI,
-- unattended agents). Kong buffers the upstream response until Straiker
-- Defend scores it. Interactive developers who need token-by-token
-- streaming should use straiker-coding-agent-streaming instead.
--
-- WHY A SECOND PLUGIN, NOT A FLAG. Kong sets ctx.buffered_proxying from
-- the existence of a `response` field on this table, before any plugin
-- code runs. A config flag cannot switch it. `response` cannot coexist
-- with body_filter, which is why this variant has no async relay.
--
-- Never attach both coding-agent plugins to the same route.
-- Do not combine this plugin with ai-proxy on streaming requests:
-- ai-proxy disables response buffering, and enforcement silently stops.

local core = require "kong.plugins.straiker.coding_agent"

local StraikerCodingAgentBuffered = {
  PRIORITY = 1000,
  VERSION  = "0.11.0",
}


function StraikerCodingAgentBuffered:access(conf)
  core.access(conf)
end


function StraikerCodingAgentBuffered:response(conf)
  core.inspect_response(conf)
end


return StraikerCodingAgentBuffered
