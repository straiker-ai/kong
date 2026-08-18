package = "kong-plugin-straiker"
version = "0.11.0-1"
supported_platforms = { "linux", "macosx" }
source = {
   url = "file://./",
}
description = {
   summary = "Straiker Defend plugins for Kong Gateway",
   detailed = [[
Straiker Defend on Kong Gateway. One rock, three plugins:

  straiker
      Chat and application LLM traffic. Pre-call and post-call events to
      the Straiker Defend webhook (POST /api/v1/detect/webhook). Designed
      to run with AI Proxy / AI Proxy Advanced.

  straiker-coding-agent-buffered
      Coding-agent traffic (Claude Code and other Anthropic Messages
      clients). Buffers the model response so a violating tool_use
      never reaches the client. Use on CI and unattended agents.

  straiker-coding-agent-streaming
      Coding-agent traffic (Claude Code and other Anthropic Messages
      clients). Streams the model response. Inspects prompts and tool
      results (indirect prompt injection). Does not stop a tool_use
      before the client runs it.

Enable with:
  KONG_PLUGINS=bundled,straiker,straiker-coding-agent-buffered,straiker-coding-agent-streaming

Never attach both coding-agent plugins to the same route. Do not attach
the webhook plugin (straiker) to a coding-agent /v1/messages route.

v0.11.0 — add coding-agent buffered and streaming plugins.
   ]],
   homepage = "https://straiker.ai",
   license = "Apache 2.0",
}
dependencies = {
   "lua >= 5.1",
   "lua-resty-http",
}
build = {
   type = "builtin",
   modules = {
      ["kong.plugins.straiker.handler"] = "kong/plugins/straiker/handler.lua",
      ["kong.plugins.straiker.schema"]  = "kong/plugins/straiker/schema.lua",
      ["kong.plugins.straiker.helpers"] = "kong/plugins/straiker/helpers.lua",
      ["kong.plugins.straiker.coding_agent"] =
         "kong/plugins/straiker/coding_agent.lua",
      ["kong.plugins.straiker.coding_agent_deny"] =
         "kong/plugins/straiker/coding_agent_deny.lua",

      ["kong.plugins.straiker-coding-agent-buffered.handler"] =
         "kong/plugins/straiker-coding-agent-buffered/handler.lua",
      ["kong.plugins.straiker-coding-agent-buffered.schema"] =
         "kong/plugins/straiker-coding-agent-buffered/schema.lua",

      ["kong.plugins.straiker-coding-agent-streaming.handler"] =
         "kong/plugins/straiker-coding-agent-streaming/handler.lua",
      ["kong.plugins.straiker-coding-agent-streaming.schema"] =
         "kong/plugins/straiker-coding-agent-streaming/schema.lua",
   },
}
