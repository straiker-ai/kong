package = "kong-plugin-straiker"
version = "0.5.0-1"
supported_platforms = { "linux", "macosx" }
source = {
   url = "file://./",
}
description = {
   summary = "Straiker Defend AI plugin for Kong Gateway",
   detailed = [[
Calls Straiker /api/v1/detect (or /api/v1/detect?agentic) on every request
flowing through Kong. Supports pre-call blocking and post-call observability
for chatbot routes; agentic-aware mode for routes fronting tool-calling
agents with full messages[] including tool_calls forwarded to Straiker.

v0.5.0 adds the `blocking` config flag. When blocking=true, the synchronous
pre-call detect fires on every agent-loop iteration — including continuations
carrying tool results — so indirect prompt injections arriving via tool output
can be blocked at the gateway (403) before the upstream LLM acts on them.
Default: false (preserves existing behavior).
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
   },
}
