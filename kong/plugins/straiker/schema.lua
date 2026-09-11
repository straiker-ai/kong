-- Config schema for straiker.
--
-- SELF-CONTAINED BY REQUIREMENT. Konnect rejects a schema that require()s
-- anything, including kong.db.schema.typedefs, and Kong streaming custom
-- plugins ship only handler.lua and schema.lua. The protocols field below
-- is the expansion of typedefs.protocols_http: constants.PROTOCOLS_WITH_
-- SUBSYSTEM filtered to subsystem "http" and sorted. The handler is free
-- to require third-party modules; this file is not.

return {
  name = "straiker",
  fields = {
    { protocols = {
        type = "set", required = true,
        default = { "grpc", "grpcs", "http", "https" },
        elements = { type = "string",
                     one_of = { "grpc", "grpcs", "http", "https" } },
    } },
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
