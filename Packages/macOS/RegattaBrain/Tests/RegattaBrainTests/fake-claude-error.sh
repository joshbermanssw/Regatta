#!/bin/bash
# Fake Claude Code stream-json agent that emits an ERROR terminal `result`
# (e.g. an API error). The parser must end the turn in `.failed`, not `.idle`,
# so the chrome never silently returns to ready.
set -u
while IFS= read -r line; do
  printf '{"type":"system","subtype":"init","session_id":"fake"}\n'
  printf '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"overloaded"}\n'
done
