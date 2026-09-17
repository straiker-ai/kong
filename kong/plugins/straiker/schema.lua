-- Config for straiker.
--
-- SELF-CONTAINED BY REQUIREMENT, not by preference. Konnect rejects a schema that
-- reaches outside itself:
--
--   "The schema.lua file must not contain any require() statements."
--   "Custom validation functions must be written in Lua and be self-contained
--    within the schema.lua file."
--   -- developer.konghq.com/custom-plugins/konnect-hybrid-mode/
--
-- So there is no `require "kong.db.schema.typedefs"`; `protocols_http` is inlined
-- below. `api.lua`, `dao.lua` and `migrations.lua` are prohibited too. We have none,
-- and the whole plugin is two files for that reason.

return {
  name = "straiker",
  fields = {
    -- Inlined `typedefs.protocols_http`, which cannot be required here.
    { protocols = {
        type = "set", required = true,
        default = { "grpc", "grpcs", "http", "https" },
        elements = { type = "string",
                     one_of = { "grpc", "grpcs", "http", "https" } },
    } },
    { config = { type = "record", fields = {

      { detect_url = {
          -- Required rather than defaulted, so that pointing a gateway at the wrong
          -- environment has to be a deliberate act rather than an omission.
          -- `referenceable` so kong.yaml can carry `{vault://env/straiker-detect-url}`
          -- and the endpoint stays an environment value rather than a committed
          -- constant.
          type = "string", required = true, referenceable = true,
          description = "Straiker detect endpoint, e.g. https://api.prod.straiker.ai/api/v3/detect",
      } },

      { api_key = {
          -- Straiker's edge resolves this key to the integration you created and
          -- derives the traffic's identity from it. So this key, not anything the
          -- plugin sends, is what decides how these turns are attributed.
          type = "string", required = true, referenceable = true,
          description = "Straiker integration API key. Use a vault reference in anything shared.",
      } },

      -- NOTE: there is no `mode` field, deliberately. Kong refuses a plugin that
      -- implements both `response` and `body_filter`, and it inspects the handler
      -- table at load time -- so the choice cannot be per-config. It is the
      -- `STRAIKER_KONG_MODE` environment variable, read once at module load. A
      -- field here would advertise a switch that cannot work.

      { timeout_ms = {
          -- Inline and blocking on the request path: a latency budget, not a
          -- generosity. A cold coding-agent session replays its whole transcript in
          -- one request, which is why the default is not tighter.
          type = "integer", default = 8000, between = { 100, 60000 },
          description = "Timeout for a synchronous scoring call.",
      } },

      { fail_closed = {
          -- Fail-open keeps developers working when Straiker is unreachable.
          -- Every fail-open path stamps `x-straiker-verdict`, so a degraded control
          -- stays visible rather than looking like a clean allow.
          type = "boolean", default = false,
          description = "Reject traffic when Straiker cannot be reached.",
      } },

      { score_request = {
          -- ⚠️ **Not every path under /v1/messages is an inference.** Claude Code
          -- fires `POST /v1/messages/count_tokens` constantly -- the large majority
          -- of requests from a single typed message -- and it carries the whole
          -- conversation but NO system prompt. Scored, it cannot be identified as
          -- Claude Code and is classified on structure alone, which is how a coding
          -- session comes to be reported as something else entirely. It also repeats
          -- a conversation that the real inference request already carries. Turn
          -- this off on any route that is not the inference endpoint.
          type = "boolean", default = true,
          description = "Score the prompt. Off for count_tokens and other REST paths.",
      } },
      { score_response = {
          type = "boolean", default = true,
          description = "Score the model's answer as well as the prompt.",
      } },

      { max_body_bytes = {
          type = "integer", default = 10485760, between = { 1024, 67108864 },
          description = "Skip scoring above this size. Hook frames reach 1 MB; 10 MB is headroom.",
      } },

      -- ---- upstream credential ----------------------------------------------
      --
      -- ⚠️ **Here rather than in `request-transformer`, and that is not a style
      -- choice.** Kong resolves `{vault://env/...}` ONLY on fields declared
      -- `referenceable`, and request-transformer's header arrays are not:
      --
      --   config.add.headers    type=array   referenceable=False
      --
      -- So the reference is passed through verbatim and the upstream receives the
      -- literal string `{vault://env/anthropic-api-key}` as its API key. It fails
      -- as a 401 from the provider, which reads exactly like a wrong key rather
      -- than like an unresolved template.
      { upstream_api_key = {
          type = "string", referenceable = true,
          description = "Model credential the GATEWAY holds. Injected on the way out.",
      } },
      { upstream_key_header = {
          type = "string", default = "x-api-key",
          description = "Header to carry it. x-api-key for Anthropic, authorization for OpenAI-style.",
      } },

      -- ---- identity the relay has to supply itself ---------------------------
      --
      -- ⚠️ **A relayed body carries neither of these, and both are read off the
      -- POSTed payload rather than off headers.** The session is `session_id` at the
      -- payload's top level, which an Anthropic Messages body simply does not have --
      -- so without help every request is given a fresh synthetic session and nothing
      -- groups into a conversation. The user is `original.processed.Meta.user`, and
      -- nothing else on a gateway path supplies one, so without it every turn is
      -- attributed to an unknown user.
      --
      -- Both are added to the DETECT payload only. The body forwarded upstream is
      -- untouched, so the model never sees them.
      { user_ref = {
          -- The FALLBACK, not the primary. An authenticated Kong Consumer wins: the
          -- handler reads `kong.client.get_consumer()` first, so a route behind
          -- key-auth/JWT/mTLS/OIDC attributes each turn to the actual caller and this
          -- field is only reached when no consumer resolved. Set it on routes with no
          -- auth, where the honest answer is the integration rather than a person.
          --
          -- ⚠️ `referenceable`, and it was MISSED here once. Without it Kong passes
          -- `{vault://env/straiker-user}` through verbatim and that literal string is
          -- archived as the turn's subject -- the same failure this file already
          -- documents for request-transformer, reproduced in our own schema. Any field
          -- that a `.env` value reaches has to carry this flag.
          type = "string", referenceable = true,
          description = "Fallback attribution when no Kong Consumer is resolved, e.g. user@example.com.",
      } },
      { session_from_body = {
          -- A digest of the preamble plus the first user message. Stable across the
          -- turns of one conversation because a transcript grows at the END, so
          -- neither of those two inputs changes as the conversation goes on.
          type = "boolean", default = true,
          description = "Derive a stable session id when the client sends no header.",
      } },

      { debug_preamble = {
          -- Logs how the request identifies itself: the shape of `system` and its
          -- first bytes. That is what decides which client Straiker believes sent
          -- the traffic, and it is invisible everywhere else, so "why was this
          -- reported as the wrong kind of agent" is hard to answer without it.
          -- Off by default: it prints prompt content to the Kong log.
          type = "boolean", default = false,
          description = "Log the system-prompt shape and lead, to explain client resolution.",
      } },

      -- ---- routing hints, all optional and all ADVISORY ----------------------
      --
      -- ⚠️ **Unset is right for a SHARED gateway and wrong for a dedicated one, and
      -- the difference is not cosmetic -- it decides what kind of agent Straiker
      -- believes this traffic is, and therefore which controls apply to it.**
      --
      -- Unset, Straiker identifies the client from the request's own system prompt,
      -- which recognises the common coding-agent surfaces. One Kong fronting several
      -- different clients has a different right answer for each, so pinning one
      -- value here would force all of them onto it.
      --
      -- But a system prompt only names a client Straiker has a marker for. Anything
      -- unrecognised is classified on request structure alone, and a plain messages
      -- array looks the same whoever sent it -- so a chat assistant speaking the
      -- Anthropic or OpenAI messages API is indistinguishable from an autonomous
      -- agent and is treated as the broader of the two. That is a deliberate safe
      -- default rather than a defect, but on a route fronting exactly one known
      -- application it is the wrong answer, and this field (or `agent_ref`) is the
      -- only way to correct it.
      --
      -- Rule of thumb: shared gateway -> leave unset. One route, one known app ->
      -- set it. An app posting the simple `{prompt}` contract needs neither; that
      -- shape is unambiguous on its own.
      { client = {
          type = "string",
          description = "Optional x-s6r-client. Leave unset on a shared gateway; set it on a single-app route.",
      } },
      { agent_ref = {
          -- Names ONE agent, never a kind of agent. Straiker keys per-agent state on
          -- this value, so sharing it across several agents merges them into one.
          -- Scope it per-route, not per-gateway.
          type = "string",
          description = "Optional x-s6r-agent. Names one agent; scope it to a route.",
      } },
      { format_hint = {
          -- Only consulted where structure cannot decide, which is the OpenAI /
          -- Anthropic `messages` ambiguity. Ignored everywhere else.
          type = "string",
          one_of = { "anthropic.messages", "openai.chat" },
          description = "Optional x-s6r-format. Only breaks the messages-array tie.",
      } },
    } } },
  },
}
