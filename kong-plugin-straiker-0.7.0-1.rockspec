package = "kong-plugin-straiker"
version = "0.7.0-1"
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

v0.6.0 — automatic per-request app source resolution. One Kong route and one
Straiker API key can serve many applications, each appearing as a distinct app
profile in the Console. `jwt_app_claim` derives the source from the JWT that
Kong's openid-connect (or jwt) plugin validated (Microsoft Entra / Azure AD);
`app_id_header` reads identity from an upstream-set header.

v0.7.0 — MCP discovery (Preview). On a route fronting a network-hosted MCP
server (Streamable HTTP / SSE), `mcp_discovery=true` parses the JSON-RPC and
emits a beforeMCPExecution event per tools/call to the Straiker detect endpoint
so the MCP server is inventoried in the Console. Server name + URL are derived
from the Kong upstream; emits are deduped per (server, tool). Requires Straiker
backend support for the configured source value. Default off.
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
