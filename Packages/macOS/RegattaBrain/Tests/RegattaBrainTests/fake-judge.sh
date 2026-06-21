#!/bin/bash
# Fake Claude Code stream-json judge for RegattaBrainLoopJudge tests.
#
# Reads newline-delimited user JSON from stdin and, for each prompt, replies
# with an affirmative verdict ("YES ...") as stream-json content_block_deltas
# followed by a message_stop — then loops, staying alive (persistent) until
# stdin closes. No network; deterministic affirmative verdict for the
# "goal met" path.
set -u
while IFS= read -r line; do
  printf '{"type":"content_block_delta","delta":{"type":"text_delta","text":"YES"}}\n'
  printf '{"type":"content_block_delta","delta":{"type":"text_delta","text":" — the goal is met."}}\n'
  printf '{"type":"message_stop"}\n'
done
