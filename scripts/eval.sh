#!/bin/bash
#
# Runs AbleKit against real tasks on this Mac and checks what actually happened.
#
# Every result is judged by an independent check — the clipboard, the file system, what is
# frontmost — never by AbleKit's own claim that it finished. A task that "completes" without doing
# the thing counts as a failure here, which is the point: the first live run of the agent completed
# nothing and claimed nothing wrong, and only an outside check could tell.
#
# It takes over the keyboard and pointer while it runs. Do not use the Mac until it finishes.
#
# Usage: scripts/eval.sh [task-name ...]      (default: all tasks)
#
# Safety on a real machine:
#   - TextEdit tasks are skipped if TextEdit is already running, because cleaning up means closing
#     documents without saving, which must never touch the user's own work.
#   - The clipboard is saved first and restored afterwards (plain text only).
#   - File tasks work only inside a temporary folder that is deleted at the end.
#
set -uo pipefail
cd "$(dirname "$0")/.."

TIMEOUT="${EVAL_TIMEOUT:-240}"
REPORT_DIR=".build/eval"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPORT_DIR/report-$STAMP.md"
WORK_DIR="$HOME/AbleKitEval-$STAMP"
mkdir -p "$REPORT_DIR"

# ------------------------------------------------------------------ helpers

quit_app() { /usr/bin/osascript -e "tell application \"$1\" to quit" >/dev/null 2>&1 || true; }
quit_textedit() { /usr/bin/osascript -e 'tell application "TextEdit" to quit saving no' >/dev/null 2>&1 || true; }
is_running() { pgrep -xq "$1"; }

probe() {
    scripts/command.sh probe
    sleep 1
    /usr/bin/log show --last 3s --style compact \
        --predicate 'subsystem == "com.ablekit.AbleKit" AND eventMessage BEGINSWITH "Probe:"' \
        | sed -n 's/.*Probe: //p' | tail -1
}
frontmost_app() { probe | sed -n 's/^app=\([^|]*\)|.*/\1/p'; }
front_window() { probe | sed -n 's/.*|window=//p'; }

clipboard_text() { pbpaste 2>/dev/null; }
clipboard_rtf() { pbpaste -Prefer rtf 2>/dev/null; }
clear_clipboard() { printf '' | pbcopy; }

TEXTEDIT_WAS_RUNNING=0
is_running TextEdit && TEXTEDIT_WAS_RUNNING=1

# ------------------------------------------------------------------ tasks
#
# Each task defines: goal_<name>, setup_<name>, check_<name> (exit 0 = pass), cleanup_<name>,
# and optionally skip_<name> (prints a reason and exits 0 to skip).

TASKS=(open_calculator textedit_type textedit_bold calculator_multiply finder_new_folder settings_appearance)

# 1. Loop A: a native launch.
goal_open_calculator="Open Calculator"
setup_open_calculator() { quit_app Calculator; sleep 1; }
check_open_calculator() { [[ "$(frontmost_app)" == "Calculator" ]]; }
cleanup_open_calculator() { quit_app Calculator; }

# 2. Menu + typing into a document + copying.
goal_textedit_type="Create a new TextEdit document, type AbleKit was here, then select all the text and copy it"
skip_textedit_type() { (( TEXTEDIT_WAS_RUNNING )) && echo "TextEdit was already open; skipped to protect unsaved work"; }
setup_textedit_type() { clear_clipboard; }
check_textedit_type() { [[ "$(clipboard_text)" == *"AbleKit was here"* ]]; }
cleanup_textedit_type() { quit_textedit; }

# 3. A nested menu command on a selection.
goal_textedit_bold="Create a new TextEdit document, type Bold move, select all of it, make it bold, then copy it"
skip_textedit_bold() { skip_textedit_type; }
setup_textedit_bold() { clear_clipboard; }
check_textedit_bold() {
    local rtf; rtf="$(clipboard_rtf)"
    [[ "$rtf" == *"Bold move"* ]] && { [[ "$rtf" == *"-Bold"* ]] || grep -q '\\b[\\ ]' <<<"$rtf"; }
}
cleanup_textedit_bold() { quit_textedit; }

# 4. Operating an app's own controls, then a menu command.
goal_calculator_multiply="Use Calculator to work out 12 times 7, then copy the result"
setup_calculator_multiply() { quit_app Calculator; clear_clipboard; sleep 1; }
check_calculator_multiply() { [[ "$(clipboard_text | tr -d '[:space:],')" == "84" ]]; }
cleanup_calculator_multiply() { quit_app Calculator; }

# 5. File management in Finder, including naming something.
goal_finder_new_folder="In the Finder window that is open, create a new folder named Eval Folder"
setup_finder_new_folder() { mkdir -p "$WORK_DIR"; open "$WORK_DIR"; sleep 2; }
check_finder_new_folder() { [[ -d "$WORK_DIR/Eval Folder" ]]; }
cleanup_finder_new_folder() {
    /usr/bin/osascript -e "tell application \"Finder\" to close (every window whose name is \"$(basename "$WORK_DIR")\")" >/dev/null 2>&1 || true
}

# 6. Navigating a complex app's structure.
goal_settings_appearance="Open System Settings and go to the Appearance settings"
setup_settings_appearance() { quit_app "System Settings"; sleep 1; }
check_settings_appearance() { [[ "$(front_window)" == *"Appearance"* ]]; }
cleanup_settings_appearance() { quit_app "System Settings"; }

# ------------------------------------------------------------------ runner

if [[ $# -gt 0 ]]; then TASKS=("$@"); fi

if ! pgrep -qf "AbleKit.app/Contents/MacOS/AbleKit"; then
    echo "==> Starting AbleKit"; open /Applications/AbleKit.app; sleep 4
fi

SAVED_CLIPBOARD="$(mktemp)"
pbpaste > "$SAVED_CLIPBOARD" 2>/dev/null || true
finish() {
    scripts/command.sh stop >/dev/null 2>&1 || true
    pbcopy < "$SAVED_CLIPBOARD"; rm -f "$SAVED_CLIPBOARD"
    rm -rf "$WORK_DIR"
}
trap finish EXIT

scripts/command.sh diagnostics on >/dev/null

{
    echo "# AbleKit evaluation — $STAMP"
    echo ""
    echo "Build: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/AbleKit.app/Contents/Info.plist) ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/AbleKit.app/Contents/Info.plist)), commit $(git rev-parse --short HEAD)"
    echo ""
    echo "| Task | Result | Agent said | Steps | Time |"
    echo "|---|---|---|---|---|"
} > "$REPORT"

PASSED=0; FAILED=0; SKIPPED=0
DETAILS="$(mktemp)"

for task in "${TASKS[@]}"; do
    goal_var="goal_$task"
    goal="${!goal_var:-}"
    if [[ -z "$goal" ]]; then echo "unknown task: $task" >&2; continue; fi

    if declare -F "skip_$task" >/dev/null; then
        reason="$("skip_$task")"
        if [[ -n "$reason" ]]; then
            echo "--- $task: SKIPPED ($reason)"
            echo "| $task | skipped | $reason | | |" >> "$REPORT"
            SKIPPED=$((SKIPPED + 1)); continue
        fi
    fi

    echo ""
    echo "=== $task: $goal"
    "setup_$task"
    started=$SECONDS
    transcript="$(scripts/ask.sh "$goal" "$TIMEOUT" 2>&1)"
    elapsed=$((SECONDS - started))
    echo "$transcript"
    sleep 1

    steps="$(grep -c '^    Step ' <<<"$transcript")"
    claim="$(sed -n 's/^    Task finished (\([a-z]*\)).*/\1/p' <<<"$transcript" | tail -1)"
    [[ -n "$claim" ]] || claim="timed out"

    if "check_$task"; then
        result="PASS"; PASSED=$((PASSED + 1))
    else
        result="FAIL"; FAILED=$((FAILED + 1))
    fi
    echo "--- $task: $result (agent said: $claim, $steps steps, ${elapsed}s)"
    echo "| $task | **$result** | $claim | $steps | ${elapsed}s |" >> "$REPORT"
    { echo ""; echo "## $task — $result"; echo ""; echo "Goal: $goal"; echo ""; echo '```'; echo "$transcript"; echo '```'; } >> "$DETAILS"

    scripts/command.sh stop >/dev/null 2>&1 || true
    "cleanup_$task"
    sleep 2
done

{
    echo ""
    echo "**$PASSED passed, $FAILED failed, $SKIPPED skipped.**"
    cat "$DETAILS"
} >> "$REPORT"
rm -f "$DETAILS"

echo ""
echo "==> $PASSED passed, $FAILED failed, $SKIPPED skipped"
echo "==> Report: $REPORT"
(( FAILED == 0 ))
