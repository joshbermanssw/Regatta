#!/bin/bash
# Fake Claude Code stream-json agent for tests.
#
# Reads newline-delimited user JSON from stdin and, for each message, emits the
# REAL Claude Code stream-json wire format produced by
# `claude -p --output-format stream-json --include-partial-messages`:
#
#   - leading `system` lifecycle noise (init + a hook pair) that the parser must
#     ignore gracefully,
#   - per-token partial text deltas wrapped in a `stream_event` envelope,
#   - the full `assistant` message,
#   - framing `stream_event`s (content_block_stop / message_stop),
#   - a terminal `result` event.
#
# Then it loops, staying alive (persistent) until stdin closes. The reply echoes
# the user's text so tests can assert the input round-tripped to the process.
set -u
while IFS= read -r line; do
  # Crude extraction of the user text. The greedy .* anchors to the LAST
  # "text":"..." field, which is the user content (not the "type":"text" tag).
  text=$(printf '%s' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
  reply="echo: ${text}"

  # System noise the parser must tolerate.
  printf '{"type":"system","subtype":"hook_started","hook":"SessionStart"}\n'
  printf '{"type":"system","subtype":"hook_response","hook":"SessionStart"}\n'
  printf '{"type":"system","subtype":"init","session_id":"fake"}\n'

  # Partial-message envelopes carrying per-token text deltas.
  printf '{"type":"stream_event","event":{"type":"message_start"}}\n'
  printf '{"type":"stream_event","event":{"type":"content_block_start","index":0}}\n'
  printf '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"echo: "}}}\n'
  printf '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"%s"}}}\n' "$text"

  # Full assistant message (parser must NOT double-append after the deltas).
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$reply"

  # Framing + terminal result.
  printf '{"type":"stream_event","event":{"type":"content_block_stop","index":0}}\n'
  printf '{"type":"stream_event","event":{"type":"message_stop"}}\n'
  printf '{"type":"result","subtype":"success","is_error":false,"result":"%s"}\n' "$reply"
done
