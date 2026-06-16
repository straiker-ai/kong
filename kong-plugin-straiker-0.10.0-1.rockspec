package = "kong-plugin-straiker"
version = "0.10.0-1"
supported_platforms = { "linux", "macosx" }
source = {
   url = "file://./",
}
description = {
   summary = "Straiker Defend AI plugin for Kong Gateway (webhook detection)",
   detailed = [[
A single Kong plugin (`straiker`) that protects AI traffic flowing through Kong.
On each request it buffers the upstream response and sends pre-call and post-call
events to the Straiker webhook API (POST /api/v1/detect/webhook), forwarding the
raw request/response envelope, extracted prompt/response text, the Kong consumer
identity, request metadata, and ai-proxy context. Straiker performs detection and
returns { action, score, turn_id }; the plugin enforces action == "block".

Detection policy lives in the Straiker Console per application — selected at
runtime by the caller's identity (the Kong consumer, e.g. mapped from a
Microsoft Entra claim via openid-connect `consumer_claim`). The gateway plugin is
intentionally near-zero-config.

Config:
  api_key    — Straiker API key (encrypted, vault-referenceable).
  detect_url — Straiker webhook endpoint (default the prod /detect/webhook).
  block      — true (default): enforce Straiker's block action on input and
               response. false: evaluate/log only, never block.
  fail_open  — true (default): if the webhook is unreachable/errors on the INPUT
               check, allow the request (availability-first). false: fail closed
               (block). Response/post-call evaluation always fails open.
  debug      — verbose request/response/webhook logging (off by default).

v0.10.0 — single webhook-based plugin; removed straiker-saas, the per-provider
          translators, the shared module tree, and the agentic detect-API shape;
          identity via the Kong consumer; re-added fail_open (fail-closed opt-in).
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
   },
}
