package = "kong-plugin-straiker"
version = "0.12.0-1"
supported_platforms = { "linux", "macosx" }
source = {
   url = "file://./",
}
description = {
   summary = "Straiker AI security plugin for Kong Gateway",
   detailed = [[
Straiker on Kong Gateway. One rock, one plugin:

  straiker
      Inspects LLM traffic on a route and enforces the Straiker verdict at
      the edge. Speaks Anthropic Messages and OpenAI chat, so the same
      plugin covers chat applications and coding agents (Claude Code and
      other Anthropic Messages clients). Scores the prompt in `access` and
      the model's answer afterwards, and injects the upstream model
      credential so the client never holds it.

Delivery mode is the STRAIKER_KONG_MODE environment variable, NOT a config
field:

  buffered (default)
      Kong holds the answer until Straiker has scored it, so a violating
      tool_use never reaches the client. Time to first token becomes the
      completion time.

  streaming
      Tokens reach the client untouched and the answer is relayed to
      Straiker afterwards. Prompts and tool results are still enforced;
      the answer's verdict is advisory because the client already has it.

It is an environment variable because Kong refuses a plugin that
implements both `response` and `body_filter`, and it inspects the handler
table at load time -- so the choice cannot be per-config. A config field
would advertise a switch that cannot work. The mode is therefore
node-wide: a node serves one mode, and changing it is a restart.

The plugin is exactly one handler.lua and one schema.lua, with no sibling
modules and no require() in the schema. That is what Kong streaming custom
plugins accept, so the same sources install as a rock, copy into a Docker
image, or upload to a Konnect Dedicated Cloud Gateway unchanged.
tools/check-plugin-layout.sh enforces it.

Enable with:
  KONG_PLUGINS=bundled,straiker

v0.12.0 -- BREAKING. The three plugins are replaced by one. Both
straiker-coding-agent-buffered and straiker-coding-agent-streaming are
removed, and `straiker` is a new implementation rather than the previous
webhook plugin: it targets the Straiker v3 detect API (POST
/api/v3/detect) instead of the v1 webhook, and its config schema is not
compatible with 0.11.x. See README.md for the field-by-field migration.

v0.11.1 -- every plugin became exactly one handler.lua and one schema.lua,
so the same sources upload to a Konnect Dedicated Cloud Gateway as
streaming custom plugins.

v0.11.0 -- added coding-agent buffered and streaming plugins.
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
