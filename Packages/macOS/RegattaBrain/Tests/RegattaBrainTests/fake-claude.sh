#!/bin/bash
# Fake Claude Code stream-json agent for tests.
#
# Reads newline-delimited user JSON from stdin and, for each message, emits a
# few stream-json content_block_delta lines followed by a message_stop — then
# loops, staying alive (persistent) until stdin closes. The reply echoes the
# user's text so tests can assert the input round-tripped to the process.
set -u
while IFS= read -r line; do
  # Crude extraction of the user text. The greedy .* anchors to the LAST
  # "text":"..." field, which is the user content (not the "type":"text" tag).
  text=$(printf '%s' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
  printf '{"type":"content_block_delta","delta":{"type":"text_delta","text":"echo: "}}\n'
  printf '{"type":"content_block_delta","delta":{"type":"text_delta","text":"%s"}}\n' "$text"
  printf '{"type":"message_stop"}\n'
done
