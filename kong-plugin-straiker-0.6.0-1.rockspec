package = "kong-plugin-straiker"
version = "0.6.0-1"
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

v0.6.0 adds automatic per-request app source resolution so one Kong route and
one Straiker API key can serve many applications and have each appear as a
distinct app profile in the Straiker Console.

Two new config fields (both default "off", preserving prior behavior):
  - jwt_app_claim ("auto" | "azp" | "appid" | "off"): use the calling app's
    identity from the JWT Kong validated. The plugin reads the verified token
    from kong.ctx.shared.authenticated_jwt_token (populated by the openid-connect
    or jwt plugin) and uses the claim as the Straiker `source`. This is the
    Microsoft Entra / Azure AD path: signature-verified by Kong, and it survives
    ai-proxy-advanced replacing the Authorization header because the token is
    read from request context, not the header. "auto" resolves
    app_displayname -> azp (Entra v2) -> appid (Entra v1); use "appid" for
    default app-only (client-credentials) tokens, which are v1.
  - app_id_header (e.g. "x-app-id"): read the app identity from a request header
    set by an upstream edge/transformer or the app itself.

Verified end-to-end against a live Entra tenant with openid-connect +
ai-proxy-advanced on a single route and key.
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
