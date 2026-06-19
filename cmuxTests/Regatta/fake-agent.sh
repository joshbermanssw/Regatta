#!/bin/bash
# fake-agent.sh — scriptable fake agent process for Regatta test harness
#
# Usage: fake-agent.sh <fixture-path>
# Fallback: FAKE_AGENT_FIXTURE env var
#
# Fixture format (one directive per line; blank lines and # comments ignored):
#   OUT <text>     → print <text> + newline to stdout (flushed)
#   ERR <text>     → print <text> + newline to stderr
#   SLEEP <ms>     → sleep <ms> milliseconds (macOS /bin/sleep supports fractions)
#   EXIT <code>    → exit immediately with <code>
#
# If the fixture ends without EXIT, exits 0.
# If the fixture path is missing or unreadable, prints an error to stderr and exits 2.

set -euo pipefail

FIXTURE="${1:-${FAKE_AGENT_FIXTURE:-}}"

if [ -z "$FIXTURE" ]; then
    echo "fake-agent: error: no fixture path provided (argv[1] or FAKE_AGENT_FIXTURE)" >&2
    exit 2
fi

if [ ! -r "$FIXTURE" ]; then
    echo "fake-agent: error: fixture not readable: $FIXTURE" >&2
    exit 2
fi

while IFS= read -r line || [ -n "$line" ]; do
    # Skip blank lines and comments
    case "$line" in
        ''|'#'*) continue ;;
    esac

    directive="${line%% *}"
    rest="${line#* }"
    # Handle the case where there's no space (directive with no argument)
    if [ "$directive" = "$line" ]; then
        rest=""
    fi

    case "$directive" in
        OUT)
            printf '%s\n' "$rest"
            ;;
        ERR)
            printf '%s\n' "$rest" >&2
            ;;
        SLEEP)
            # Convert ms to fractional seconds; macOS /bin/sleep accepts decimals
            seconds=$(awk "BEGIN { printf \"%.6f\", $rest / 1000 }")
            /bin/sleep "$seconds"
            ;;
        EXIT)
            exit "$rest"
            ;;
        *)
            echo "fake-agent: warning: unknown directive: $directive" >&2
            ;;
    esac
done < "$FIXTURE"

exit 0
