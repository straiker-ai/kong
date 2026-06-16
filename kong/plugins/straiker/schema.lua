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
              default = "https://api.prod.straiker.ai/api/v1/detect/webhook",
            } },
          { block = {
              -- When true, Straiker detections can block both the incoming agent
              -- turn and the final model response. When false, detections are
              -- evaluated and logged but traffic is never blocked.
              type = "boolean",
              default = true,
            } },
          { fail_open = {
              -- Behaviour when the Straiker webhook is unreachable or errors on the
              -- INPUT (pre-call) check. true (default) = allow the request through
              -- (availability-first). false = fail CLOSED — block the request when
              -- the guardrail can't be reached. (Response/post-call evaluation
              -- always fails open: a real model answer is never withheld because
              -- the scorer was down.)
              type = "boolean",
              default = true,
            } },
          { debug = {
              -- Enables verbose request/response/webhook logging for local
              -- validation. Keep disabled in normal deployments.
              type = "boolean",
              default = false,
            } },
        },
    } },
  },
}
