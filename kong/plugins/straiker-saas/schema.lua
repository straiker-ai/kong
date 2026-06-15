local typedefs = require "kong.db.schema.typedefs"

-- straiker-saas — config schema.
--
-- Mirrors the `straiker` plugin's config, MINUS the streaming/compat and MCP
-- options that don't apply to the buffered response-phase design, PLUS one new
-- field: block_response (post-call output blocking, which the timer build can't
-- do). Field names and defaults are kept identical to `straiker` so an operator
-- can move a route between the two builds with the same config block.

return {
  name = "straiker-saas",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { api_key = {
              type = "string",
              required = true,
              encrypted = true,
              referenceable = true,
            } },
          { detect_url = {
              type = "string",
              default = "https://api.prod.straiker.ai/api/v1/detect",
            } },
          { mode = {
              -- pre_call  → input guardrail only (access phase).
              -- post_call → response evaluation only (response phase).
              -- both      → input guardrail + response evaluation (default).
              type = "string",
              default = "both",
              one_of = { "pre_call", "post_call", "both" },
            } },
          { agentic = {
              type = "boolean",
              default = false,
            } },
          { destination = {
              type = "string",
              default = "api.openai.com",
            } },
          { source = {
              type = "string",
              default = "kong-plugin",
            } },
          { threshold = {
              type = "number",
              default = 0.5,
              between = { 0, 1 },
            } },
          { timeout = {
              type = "number",
              default = 5000,
            } },
          { fail_open = {
              -- On a failed/non-200 Straiker call: true → allow traffic through
              -- (input) / forward the upstream answer (response). false → 503 on
              -- input; response eval always fails open (never withhold a real
              -- answer because the scorer was unreachable).
              type = "boolean",
              default = false,
            } },
          { blocking = {
              -- Pre-call input blocking. When true, the access-phase guardrail
              -- runs on every agent-loop iteration (even in post_call mode) so an
              -- indirect injection arriving in a tool result is scored and can be
              -- blocked before the upstream model acts on it.
              type = "boolean",
              default = false,
            } },
          { block_response = {
              -- Response-phase output blocking (NEW vs. the timer build). When
              -- true and the model's answer scores over `threshold`, the answer is
              -- withheld and replaced (403 if verbose_block, else a safe 200). When
              -- false (default) the response phase scores for visibility only and
              -- always forwards the original answer.
              type = "boolean",
              default = false,
            } },
          { verbose_block = {
              -- true  → blocks return HTTP 403 (visible in API clients/Postman).
              -- false → blocks return an OpenAI-compatible 200 with a safe message
              --         so the agent loop terminates without revealing Straiker.
              type = "boolean",
              default = false,
            } },
          { app_id_header = {
              -- Tier 1 app-source: request header carrying the app id (e.g.
              -- "x-app-id"). "off" = disabled. See handler resolve_app_source.
              type = "string",
              default = "off",
            } },
          { jwt_app_claim = {
              -- Tiers 2-3 app-source: JWT claim to use as the per-request app
              -- (Microsoft Entra / Azure AD path; pair with openid-connect).
              -- "auto" → app_displayname → azp (v2) → appid (v1); "azp"; "appid";
              -- "off" (default). Reads the verified token from
              -- kong.ctx.shared.authenticated_jwt_token, falling back to the
              -- Authorization header. See handler resolve_app_source.
              type = "string",
              default = "off",
            } },
        },
    } },
  },
}
