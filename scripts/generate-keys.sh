#!/bin/bash
#
# Creates the EdDSA key pair Sparkle uses to prove an update really came from this project.
#
# Run this ONCE, ever. The private key goes into your login keychain; the public key goes into
# Configs/Info.plist and is committed. Losing the private key means no existing installation can
# ever be updated again, so export a backup and keep it somewhere durable.
#
# The keychain will ask permission to store the key. That prompt is expected.
#
#   scripts/generate-keys.sh            create the key and show the public half
#   scripts/generate-keys.sh --export   print the private key, for a CI secret or a backup
#
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sparkle-tools.sh

GENERATE_KEYS="$(find_sparkle_tool generate_keys)"

if [[ "${1:-}" == "--export" ]]; then
    # Written to a file rather than stdout so it does not linger in shell history or scrollback.
    EXPORT_PATH="${2:-sparkle-private-key.txt}"
    "$GENERATE_KEYS" -x "$EXPORT_PATH"
    chmod 600 "$EXPORT_PATH"
    echo ""
    echo "Private key written to $EXPORT_PATH."
    echo "Store it as the SPARKLE_PRIVATE_KEY repository secret, back it up, then delete the file."
    exit 0
fi

echo "==> Generating (or reading) the Sparkle signing key"
OUTPUT="$("$GENERATE_KEYS" 2>&1)"
echo "$OUTPUT"

# The public key is the base64 blob on the SUPublicEDKey line of the snippet it prints.
PUBLIC_KEY="$(echo "$OUTPUT" | grep -A1 "SUPublicEDKey" | grep -o '<string>[^<]*</string>' | sed 's/<\/*string>//g' | head -1)"
if [[ -z "$PUBLIC_KEY" ]]; then
    PUBLIC_KEY="$("$GENERATE_KEYS" -p 2>/dev/null | tr -d '[:space:]')"
fi

if [[ -z "$PUBLIC_KEY" ]]; then
    echo ""
    echo "Could not read the public key automatically. Copy it from the output above into"
    echo "Configs/Info.plist as the value of SUPublicEDKey."
    exit 1
fi

echo ""
echo "==> Writing the public key into Configs/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBLIC_KEY" Configs/Info.plist
echo "    SUPublicEDKey = $PUBLIC_KEY"
echo ""
echo "Commit Configs/Info.plist. Until that key ships in a build, AbleKit refuses every update."
echo "Back the private key up now:  scripts/generate-keys.sh --export"
