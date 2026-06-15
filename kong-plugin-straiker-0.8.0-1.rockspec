package = "kong-plugin-straiker"
version = "0.8.0-1"
supported_platforms = { "linux", "macosx" }
source = {
   url = "file://./",
}
description = {
   summary = "Straiker Defend AI plugins for Kong Gateway (self-hosted, hybrid, full SaaS)",
   detailed = [[
Two Kong plugins that call Straiker /api/v1/detect (or /api/v1/detect?agentic)
on AI traffic flowing through Kong — pre-call input blocking, post-call response
observability, agentic tool-trace forwarding, and automatic per-request app
source resolution (Microsoft Entra / Azure AD via jwt_app_claim, or app_id_header).

Pick the plugin by deployment topology:

  straiker      — self-hosted Kong (OSS/Enterprise) and Konnect hybrid
                  (self-managed data plane). Timer-based post-call detection
                  (fire-and-forget, streaming-friendly). Full feature set.

  straiker-saas — Konnect full-SaaS Dedicated Cloud Gateways. Uses Kong's
                  buffered `response` phase instead of a timer (the Dedicated
                  Cloud custom-plugin sandbox forbids background timers), so it
                  runs unmodified there as two self-contained files. Synchronous
                  input blocking + agentic trace + app-source resolution, plus
                  synchronous RESPONSE evaluation and RESPONSE blocking. Trade-off:
                  the response phase buffers the upstream answer, so token
                  streaming (stream:true) and HTTP/2/gRPC upstreams are not
                  supported on this build — use `straiker` where streaming matters.

For Dedicated Cloud you do not need this rock: upload kong/plugins/straiker-saas/
handler.lua + schema.lua via the Konnect UI/API. This rock is for self-hosted and
hybrid installs, where it makes both plugins available; enable whichever you need
via KONG_PLUGINS (e.g. `bundled,straiker` or `bundled,straiker-saas`).

v0.6.0 — automatic per-request app source resolution.
v0.7.0 — MCP discovery (preview, off by default) on the `straiker` plugin.
v0.8.0 — adds the `straiker-saas` (response-phase) plugin for Konnect Dedicated
         Cloud / full-SaaS gateways. The `straiker` plugin is unchanged.
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
   },
}
