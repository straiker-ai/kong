-- Config schema for straiker-coding-agent-streaming.
--
-- SELF-CONTAINED BY REQUIREMENT. Konnect hybrid rejects a schema that
-- require()s anything, including typedefs. The handler is free to require
-- shared modules; this file is not.
--
-- The shared field block is duplicated with straiker-coding-agent-buffered.
-- Keep the two copies byte-identical when you edit either.

-- >>> SHARED BLOCK -- keep byte-identical with straiker-coding-agent-buffered <<<
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
-- >>> END SHARED BLOCK <<<

shared_fields[#shared_fields + 1] = { relay_response = {
    type = "boolean", default = true,
    description = "Relay the model's streamed response to Straiker Defend after it has shipped.",
} }
shared_fields[#shared_fields + 1] = { relay_timeout_ms = {
    type = "integer", default = 15000, between = { 100, 120000 },
    description = "Timeout for the asynchronous response relay, in milliseconds.",
} }

return {
  name = "straiker-coding-agent-streaming",
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
