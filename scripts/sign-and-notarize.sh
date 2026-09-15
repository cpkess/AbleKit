#!/bin/bash
#
# Signs, notarizes and staples an artifact (a .app or a .dmg).
#
# Notarization is not optional for anything a user downloads: without a stapled ticket, Gatekeeper
# refuses to open the app at all on a machine that has never seen it, and the user gets a dialog
# implying the software is malicious rather than merely unnotarized.
#
# Credentials come from the environment and are never written to disk by this script:
#   SIGNING_IDENTITY     "Developer ID Application: Example Ltd (TEAMID)"
#   AC_API_KEY_PATH      path to the App Store Connect .p8 key
#   AC_API_KEY_ID        key id
#   AC_API_ISSUER_ID     issuer id
#
# Usage: scripts/sign-and-notarize.sh <artifact> [entitlements]
#
set -euo pipefail

ARTIFACT="${1:?usage: sign-and-notarize.sh <artifact> [entitlements]}"
ENTITLEMENTS="${2:-}"

: "${SIGNING_IDENTITY:?SIGNING_IDENTITY is not set}"
: "${AC_API_KEY_PATH:?AC_API_KEY_PATH is not set}"
: "${AC_API_KEY_ID:?AC_API_KEY_ID is not set}"
: "${AC_API_ISSUER_ID:?AC_API_ISSUER_ID is not set}"

echo "==> Signing $ARTIFACT"
SIGN_ARGS=(
    --force
    --sign "$SIGNING_IDENTITY"
    --timestamp          # a trusted timestamp keeps the signature valid after the cert expires
    --options runtime    # Hardened Runtime, which notarization requires
)
if [[ -n "$ENTITLEMENTS" ]]; then
    SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
fi

if [[ "$ARTIFACT" == *.app ]]; then
    # Nested code (Sparkle's framework, its XPC services) must be signed before the outer bundle,
    # or the outer signature seals over unsigned contents and notarization rejects it.
    while IFS= read -r nested; do
        echo "    signing nested: ${nested#"$ARTIFACT"/}"
        codesign "${SIGN_ARGS[@]}" "$nested"
    done < <(find "$ARTIFACT/Contents/Frameworks" \
        -depth \( -name "*.framework" -o -name "*.xpc" -o -name "*.dylib" -o -name "*.app" \) \
        2>/dev/null || true)
fi

codesign "${SIGN_ARGS[@]}" "$ARTIFACT"
codesign --verify --deep --strict --verbose=2 "$ARTIFACT"

echo "==> Submitting for notarization"
SUBMISSION="$ARTIFACT"
if [[ "$ARTIFACT" == *.app ]]; then
    # notarytool takes an archive, not a bundle directory.
    SUBMISSION="$(mktemp -d)/$(basename "$ARTIFACT").zip"
    ditto -c -k --keepParent "$ARTIFACT" "$SUBMISSION"
fi

xcrun notarytool submit "$SUBMISSION" \
    --key "$AC_API_KEY_PATH" \
    --key-id "$AC_API_KEY_ID" \
    --issuer "$AC_API_ISSUER_ID" \
    --wait

echo "==> Stapling the ticket"
# Stapling matters because it is what lets the app open on a Mac that is offline or behind a
# firewall: without it Gatekeeper has to reach Apple to confirm the notarization.
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"

echo "==> $ARTIFACT is signed, notarized and stapled"
