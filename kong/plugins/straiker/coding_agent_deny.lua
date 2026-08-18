-- Synthesize a Straiker Defend block as an Anthropic Messages assistant turn.
--
-- Always HTTP 200. Coding-agent clients such as Claude Code map 403 to
-- "Please run /login", retry 408/409/429/5xx/529, and treat stop_reason
-- "refusal" as an Anthropic Acceptable Use Policy kill. A completed
-- end_turn keeps the session alive and shows the policy text to the user.

local cjson = require "cjson.safe"

local STOP_REASON = "end_turn"

local EMPTY_ARRAY = cjson.empty_array
                    or (cjson.array_mt and setmetatable({}, cjson.array_mt))
                    or {}

local _M = {}


local function sse(event, data)
  return "event: " .. event .. "\ndata: " .. cjson.encode(data) .. "\n\n"
end


--- Replace the upstream response with a policy message the developer can read.
-- @param reason  human-facing text from Detect `stopReason` (never
--                `permissionDecisionReason`, which is addressed to the model)
-- @param streaming  whether the client asked for SSE
function _M.exit(reason, model, msg_id, streaming, headers)
  if not streaming then
    headers["Content-Type"] = "application/json"
    return kong.response.exit(200, {
      id = msg_id, type = "message", role = "assistant", model = model,
      content = { { type = "text", text = reason } },
      stop_reason = STOP_REASON, stop_sequence = cjson.null,
      usage = { input_tokens = 0, output_tokens = 0 },
    }, headers)
  end

  headers["Content-Type"]  = "text/event-stream"
  headers["Cache-Control"] = "no-cache"
  return kong.response.exit(200, table.concat({
    sse("message_start", { type = "message_start", message = {
      id = msg_id, type = "message", role = "assistant", model = model,
      content = EMPTY_ARRAY, stop_reason = cjson.null, stop_sequence = cjson.null,
      usage = { input_tokens = 0, output_tokens = 0 } } }),
    sse("content_block_start", { type = "content_block_start", index = 0,
      content_block = { type = "text", text = "" } }),
    sse("content_block_delta", { type = "content_block_delta", index = 0,
      delta = { type = "text_delta", text = reason } }),
    sse("content_block_stop", { type = "content_block_stop", index = 0 }),
    sse("message_delta", { type = "message_delta",
      delta = { stop_reason = STOP_REASON, stop_sequence = cjson.null },
      usage = { output_tokens = 0 } }),
    sse("message_stop", { type = "message_stop" }),
  }), headers)
end


return _M
