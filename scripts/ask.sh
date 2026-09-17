#!/bin/bash
#
# Gives AbleKit a goal and follows the task until it finishes.
#
# Usage: scripts/ask.sh "Open System Settings" [timeout-seconds]
#
set -euo pipefail
cd "$(dirname "$0")/.."

GOAL="${1:?usage: ask.sh GOAL [timeout]}"
TIMEOUT="${2:-300}"

FIFO="$(mktemp -u)"
mkfifo "$FIFO"
/usr/bin/log stream --style compact --level info \
    --predicate 'subsystem == "com.ablekit.AbleKit" AND category != "Command"' > "$FIFO" &
STREAM=$!
cleanup() {
    kill "$STREAM" 2>/dev/null || true
    # Reaping it here keeps bash from printing a "Terminated" notice for the stream we just stopped.
    wait "$STREAM" 2>/dev/null || true
    rm -f "$FIFO"
}
trap cleanup EXIT

exec 3<"$FIFO"
# Give the stream a moment to attach, so the first steps are not missed.
sleep 1

echo "==> Asking AbleKit: $GOAL"
scripts/command.sh ask "$GOAL"

DEADLINE=$((SECONDS + TIMEOUT))
STATUS=1
while (( SECONDS < DEADLINE )); do
    if IFS= read -r -t 5 line <&3; then
        # Keep only the message. A compact line reads
        #   <time> Df AbleKit[pid:tid] [com.ablekit.AbleKit:Agent] Task finished ...
        # so everything up to the subsystem tag, and the tag itself, is dropped.
        [[ "$line" == *"[com.ablekit.AbleKit:"* ]] || continue
        message="${line#*\[com.ablekit.AbleKit:}"
        message="${message#*\] }"
        [[ "$message" == Phase:* ]] && continue
        echo "    $message"
        if [[ "$message" == Task\ finished* ]]; then
            [[ "$message" == *"(completed)"* ]] && STATUS=0
            break
        fi
    fi
done

if (( SECONDS >= DEADLINE )); then
    echo "==> Still running after ${TIMEOUT}s; 'make stop-task' to stop it" >&2
fi
exit $STATUS
