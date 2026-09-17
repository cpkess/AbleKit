#!/bin/bash
#
# Sends a command to the running AbleKit.
#
#   scripts/command.sh palette | settings | setup | status | stop
#   scripts/command.sh diagnostics on|off
#   scripts/command.sh ask "Open System Settings"      (Debug builds only)
#
set -euo pipefail

COMMAND="$*"
if [[ -z "$COMMAND" ]]; then
    echo "usage: command.sh <palette|settings|setup|status|stop|diagnostics on|off|ask GOAL>" >&2
    exit 1
fi

if ! pgrep -qf "AbleKit.app/Contents/MacOS/AbleKit"; then
    echo "==> AbleKit is not running; starting it"
    open /Applications/AbleKit.app
    sleep 3
fi

# The command travels in an environment variable rather than being spliced into the script text,
# so a goal containing quotes cannot change what the script does.
ABLEKIT_COMMAND="$COMMAND" /usr/bin/osascript -l JavaScript -e '
ObjC.import("Foundation");
const command = $.NSProcessInfo.processInfo.environment.objectForKey("ABLEKIT_COMMAND");
$.NSDistributedNotificationCenter.defaultCenter
    .postNotificationNameObjectUserInfoDeliverImmediately(
        "com.ablekit.AbleKit.command", command, $(), true);
' >/dev/null
