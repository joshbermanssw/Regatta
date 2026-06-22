#!/bin/bash
# Fake Claude Code stream-json agent that emits NO partial `stream_event` deltas
# — only the full `assistant` message + terminal `result`. This is the shape seen
# when `--include-partial-messages` is absent or a turn produces no streamed
# tokens; the parser must still surface the assistant text from the full message.
set -u
while IFS= read -r line; do
  text=$(printf '%s' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
  reply="echo: ${text}"
  printf '{"type":"system","subtype":"init","session_id":"fake"}\n'
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$reply"
  printf '{"type":"result","subtype":"success","is_error":false,"result":"%s"}\n' "$reply"
done
