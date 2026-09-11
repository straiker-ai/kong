-- Config schema for straiker-coding-agent-buffered.
--
-- SELF-CONTAINED BY REQUIREMENT. Konnect rejects a schema that require()s
-- anything, including kong.db.schema.typedefs, and Kong streaming custom
-- plugins ship only handler.lua and schema.lua. The protocols field below
-- is the expansion of typedefs.protocols_http: constants.PROTOCOLS_WITH_
-- SUBSYSTEM filtered to subsystem "http" and sorted.
--
-- The shared field block is duplicated with straiker-coding-agent-streaming.
-- Keep the two copies byte-identical: tools/check-shared-blocks.sh fails
-- when they drift.

-- >>> BEGIN SHARED FIELDS <<<
local shared_fields = {
  { detect_url = {
      type = "string", match = "^https?://",
      default = "https://api.prod.straiker.ai/api/v1/detect",
      description = "Straiker Defend Detect endpoint (POST /api/v1/detect).",
  } },
  { api_key = {
      type = "string", required = true, encrypted = true, referenceable = true,
      description = "Straiker Defend API key. Prefer a Kong vault reference.",
  } },
  { timeout_ms = {
      type = "integer", default = 5000, between = { 100, 60000 },
      description = "Timeout for a synchronous scoring call, in milliseconds.",
  } },
  { fail_open = {
      type = "boolean", default = true,
      description = "If Straiker Defend is unreachable or errors, allow traffic when true; reject with 503 when false. Applies to the request and the response phase.",
  } },
  { max_response_bytes = {
      type = "integer", default = 8388608, between = { 1024, 67108864 },
      description = "Skip response scoring above this size, in bytes.",
  } },
}
-- >>> END SHARED FIELDS <<<

return {
  name = "straiker-coding-agent-buffered",
  fields = {
    { protocols = {
        type = "set", required = true,
        default = { "grpc", "grpcs", "http", "https" },
        elements = { type = "string",
                     one_of = { "grpc", "grpcs", "http", "https" } },
    } },
    { config = { type = "record", fields = shared_fields } },
  },
}
