#!/bin/bash
#
# Signs an app bundle or a disk image with a Developer ID identity.
#
# Usage: scripts/sign-app.sh <artifact> [identity]
#
set -euo pipefail

ARTIFACT="${1:?usage: sign-app.sh <artifact> [identity]}"
IDENTITY="${2:-${SIGNING_IDENTITY:?no identity given and SIGNING_IDENTITY is unset}}"
ENTITLEMENTS="${ENTITLEMENTS:-Configs/AbleKit.entitlements}"

echo "==> Signing $(basename "$ARTIFACT")"

SIGN_ARGS=(
    --force
    --sign "$IDENTITY"
    --timestamp        # keeps the signature valid after the certificate expires
    --options runtime  # Hardened Runtime, which notarization requires
)

if [[ "$ARTIFACT" == *.app ]]; then
    SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")

    # Nested code must be signed before the bundle that contains it. Signing outside-in seals the
    # outer signature over unsigned contents, which notarization rejects — it is the single most
    # common reason a first release fails.
    while IFS= read -r nested; do
        [[ -n "$nested" ]] || continue
        echo "    nested: ${nested#"$ARTIFACT"/}"
        codesign --force --sign "$IDENTITY" --timestamp --options runtime "$nested"
    done < <(find "$ARTIFACT/Contents/Frameworks" \
        -depth \( -name "*.framework" -o -name "*.xpc" -o -name "*.dylib" -o -name "*.app" \) \
        2>/dev/null || true)
fi

codesign "${SIGN_ARGS[@]}" "$ARTIFACT"
codesign --verify --deep --strict --verbose=2 "$ARTIFACT" 2>&1 | sed 's/^/    /'
echo "==> Signed"
