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
        },
    } },
  },
}
