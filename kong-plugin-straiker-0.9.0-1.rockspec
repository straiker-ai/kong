package = "kong-plugin-straiker"
version = "0.9.0-1"
supported_platforms = { "linux", "macosx" }
source = {
   url = "file://./",
}
description = {
   summary = "Straiker Defend AI plugins for Kong Gateway (self-hosted, hybrid, full SaaS)",
   detailed = [[
Two Kong plugins that call Straiker /api/v1/detect (or /api/v1/detect?agentic)
on AI traffic flowing through Kong — pre-call input blocking, post-call response
observability/blocking, agentic tool-trace forwarding, multi-provider response
normalization, and automatic per-request app source resolution.

Plugins:
  straiker      — self-hosted Kong (OSS/Enterprise) and Konnect hybrid. Timer-based
                  post-call (fire-and-forget, streaming-friendly).
  straiker-saas — Konnect Dedicated Cloud. Buffered `response` phase (no timers),
                  synchronous response eval + response blocking.

Both share kong.plugins.straiker-shared (helpers + per-provider translators).

Identity / app source resolution (resolve_app_source), in order:
  1. app_id_header — a request header (e.g. x-app-id) set upstream.
  2. Kong consumer — consumer.username/custom_id (the Kong-native identity model;
     map an IdP claim to a consumer via openid-connect consumer_claim).
  3. jwt_app_claim — a validated JWT claim. Microsoft Entra / Azure AD app-only
     tokens carry the calling app's client id in azp (v2) / appid (v1); "auto"
     resolves app_displayname -> azp -> appid. Enables Entra enumeration with no
     pre-created consumer.
User identity (resolve_user_name): x-user-name -> JWT email/preferred_username/
cognito:username/sub -> OpenAI `user` -> consumer.

v0.6.0 — automatic per-request app enumeration.
v0.8.0 — straiker-saas (response-phase) plugin for Konnect Dedicated Cloud.
v0.9.0 — shared helpers + per-provider translators (OpenAI/Anthropic/Bedrock/
         Gemini/Cohere/AzureAI), original-request-body read from ai-proxy context,
         Anthropic tool_use->tool_calls, Kong-consumer identity model, and the
         jwt_app_claim (azp/appid) Entra tier retained alongside it.

NOTE for Konnect Dedicated Cloud: the custom-plugin sandbox accepts two files and
blocks custom-module requires. Because straiker-saas now requires straiker-shared,
the Dedicated Cloud upload must bundle/inline the shared modules into a single
handler.lua. Self-hosted and Konnect hybrid (this rock / a Docker image that ships
the straiker-shared directory) are unaffected.
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
      ["kong.plugins.straiker.handler"]      = "kong/plugins/straiker/handler.lua",
      ["kong.plugins.straiker.schema"]       = "kong/plugins/straiker/schema.lua",
      ["kong.plugins.straiker-saas.handler"] = "kong/plugins/straiker-saas/handler.lua",
      ["kong.plugins.straiker-saas.schema"]  = "kong/plugins/straiker-saas/schema.lua",
      ["kong.plugins.straiker-shared.helpers"]               = "kong/plugins/straiker-shared/helpers.lua",
      ["kong.plugins.straiker-shared.translator.init"]       = "kong/plugins/straiker-shared/translator/init.lua",
      ["kong.plugins.straiker-shared.translator.model"]      = "kong/plugins/straiker-shared/translator/model.lua",
      ["kong.plugins.straiker-shared.translator.openai"]     = "kong/plugins/straiker-shared/translator/openai.lua",
      ["kong.plugins.straiker-shared.translator.anthropic"]  = "kong/plugins/straiker-shared/translator/anthropic.lua",
      ["kong.plugins.straiker-shared.translator.bedrock"]    = "kong/plugins/straiker-shared/translator/bedrock.lua",
      ["kong.plugins.straiker-shared.translator.gemini"]     = "kong/plugins/straiker-shared/translator/gemini.lua",
      ["kong.plugins.straiker-shared.translator.cohere"]     = "kong/plugins/straiker-shared/translator/cohere.lua",
      ["kong.plugins.straiker-shared.translator.azureai"]    = "kong/plugins/straiker-shared/translator/azureai.lua",
      ["kong.plugins.straiker-shared.translator.kong"]       = "kong/plugins/straiker-shared/translator/kong.lua",
   },
}
