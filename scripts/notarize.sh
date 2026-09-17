#!/bin/bash
#
# Notarises an artifact and staples the ticket to it.
#
# Without notarization, Gatekeeper refuses to open the app on any Mac that has never seen it, and
# tells the user it is damaged — which reads as "this is malware", not "this is unnotarised".
#
# Credentials, in order of preference:
#   1. A stored notarytool profile:  NOTARY_PROFILE=AbleKit
#      Create one once with:  xcrun notarytool store-credentials AbleKit \
#                               --key <AuthKey.p8> --key-id <id> --issuer <uuid>
#   2. An App Store Connect API key: AC_API_KEY_PATH, AC_API_KEY_ID, AC_API_ISSUER_ID
#
# Usage: scripts/notarize.sh <artifact>
#
set -euo pipefail

ARTIFACT="${1:?usage: notarize.sh <artifact>}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AbleKit}"

if [[ ! -e "$ARTIFACT" ]]; then
    echo "error: $ARTIFACT does not exist. Run 'make dmg' first." >&2
    exit 1
fi

CREDENTIALS=()
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "==> Using the stored notarytool profile '$NOTARY_PROFILE'"
    CREDENTIALS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${AC_API_KEY_PATH:-}" && -n "${AC_API_KEY_ID:-}" && -n "${AC_API_ISSUER_ID:-}" ]]; then
    echo "==> Using the App Store Connect API key"
    CREDENTIALS=(--key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID")
else
    cat >&2 <<'NOTE'
error: no notarization credentials.

Notarization needs an App Store Connect API key, which only an Account Holder or Admin can create:

  1. App Store Connect > Users and Access > Integrations > App Store Connect API
  2. Generate a key with the Developer role, and download the .p8 (once only)
  3. Store it, once, so you never have to think about it again:

       xcrun notarytool store-credentials AbleKit \
         --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 \
         --key-id XXXXXXXXXX \
         --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

Then re-run: make notarize
NOTE
    exit 1
fi

# A .app has to be zipped for submission; a .dmg is submitted as-is.
SUBMISSION="$ARTIFACT"
TEMP_DIR=""
if [[ "$ARTIFACT" == *.app ]]; then
    TEMP_DIR="$(mktemp -d)"
    SUBMISSION="$TEMP_DIR/$(basename "$ARTIFACT").zip"
    ditto -c -k --keepParent "$ARTIFACT" "$SUBMISSION"
fi
# Written as an if, not `[[ ]] && rm`: an EXIT trap's last status becomes the script's, so the
# short form made every successful DMG notarization report failure when there was nothing to remove.
cleanup() {
    if [[ -n "$TEMP_DIR" ]]; then rm -rf "$TEMP_DIR"; fi
}
trap cleanup EXIT

echo "==> Submitting $(basename "$ARTIFACT") — this usually takes a few minutes"
# notarytool exits successfully even when Apple rejects the submission, so the verdict is read
# from its JSON output rather than trusted from the exit status.
RESULT="$(xcrun notarytool submit "$SUBMISSION" "${CREDENTIALS[@]}" --wait --output-format json)"
STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' <<<"$RESULT")"
SUBMISSION_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' <<<"$RESULT")"

if [[ "$STATUS" != "Accepted" ]]; then
    echo "" >&2
    echo "error: Apple did not accept the submission (status: ${STATUS:-unknown})." >&2
    if [[ -n "$SUBMISSION_ID" ]]; then
        echo "Apple's reasons:" >&2
        xcrun notarytool log "$SUBMISSION_ID" "${CREDENTIALS[@]}" 2>/dev/null \
            | python3 -c '
import json, sys
log = json.load(sys.stdin)
for issue in log.get("issues") or []:
    print("  -", issue.get("path", "").split(".dmg/")[-1] + ":", issue.get("message"))
' >&2 || true
    fi
    exit 1
fi
echo "==> Accepted (submission $SUBMISSION_ID)"

echo "==> Stapling"
# Stapling is what lets the app open on a Mac that is offline: without it, Gatekeeper has to reach
# Apple to confirm the notarization, and refuses when it cannot.
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
echo "==> $(basename "$ARTIFACT") is notarised and stapled"
