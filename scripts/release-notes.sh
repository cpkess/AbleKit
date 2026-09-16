#!/bin/bash
#
# Prints the CHANGELOG section for a version, for release notes and the update dialog.
#
# Usage: scripts/release-notes.sh <version>
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release-notes.sh <version>}"

NOTES="$(awk -v version="$VERSION" '
    $0 ~ "^## \\[?" version { found = 1; next }
    found && /^## / { exit }
    found { print }
' CHANGELOG.md 2>/dev/null | sed '/^[[:space:]]*$/d')"

if [[ -z "$NOTES" ]]; then
    echo "AbleKit $VERSION."
else
    echo "$NOTES"
fi
