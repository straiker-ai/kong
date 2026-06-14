local typedefs = require "kong.db.schema.typedefs"

return {
  name = "straiker",
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
              type = "boolean",
              default = false,
            } },
          { ai_proxy_advanced_compat = {
              type = "boolean",
              default = false,
            } },
          { blocking = {
              type = "boolean",
              default = false,
            } },
          { verbose_block = {
              type = "boolean",
              default = false,
            } },
          { app_id_header = {
              -- Tier 1. Request header name that already carries the app id
              -- (e.g. "x-app-id"). Highest-priority source. Use when an upstream
              -- edge component, a request-transformer, or the calling app sets
              -- the header directly.
              -- NOTE: Kong openid-connect's claim-to-header injection maps
              -- id_token / userinfo claims, NOT bearer access-token claims, so it
              -- does not populate this for app-only Entra tokens — use
              -- jwt_app_claim (Tier 2) for the Entra/Azure AD flow.
              -- "off" = disabled (default).
              type = "string",
              default = "off",
            } },
          { jwt_app_claim = {
              -- Tiers 2-3. JWT claim to use as the per-request source. This is the
              -- Microsoft Entra / Azure AD path; pair with Kong's openid-connect
              -- (or jwt) plugin.
              -- "auto"  → tries app_displayname → azp (Entra v2) → appid (Entra v1)
              --           Recommended: real app-only (client-credentials) tokens
              --           default to v1 and carry `appid`, not `azp`.
              -- "azp"   → Entra v2 authorized-party / app registration client ID
              -- "appid" → Entra v1 app registration client ID
              -- "off"   → disabled; use configured source as-is (default)
              -- Where the verified JWT comes from:
              --   1. kong.ctx.shared.authenticated_jwt_token — set by the
              --      openid-connect plugin (Entra, validated vs tenant JWKS) OR
              --      the free jwt plugin. Survives ai-proxy-advanced replacing
              --      the Authorization header (it is request context). PREFERRED.
              --   2. Authorization: Bearer header (direct decode) — fallback for
              --      routes with no auth plugin; NOT available once ai-proxy /
              --      ai-proxy-advanced has replaced the header.
              type = "string",
              default = "off",
            } },
        },
    } },
  },
}
