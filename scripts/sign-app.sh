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
    FRAMEWORKS="$ARTIFACT/Contents/Frameworks"
    NESTED_ARGS=(--force --sign "$IDENTITY" --timestamp --options runtime)

    # Nested code must be signed before whatever contains it. Signing outside-in seals the outer
    # signature over contents that are then changed, which notarization rejects.
    #
    # Loose executables come first, and they are found by content rather than by name: Sparkle
    # ships a bare helper called `Autoupdate` inside its framework, with no extension at all. A
    # search for bundles and dylibs walks straight past it, and Apple then rejects the whole
    # submission because that one binary still carries Sparkle's own signature.
    if [[ -d "$FRAMEWORKS" ]]; then
        while IFS= read -r binary; do
            [[ -n "$binary" ]] || continue
            file -b "$binary" | grep -q "Mach-O" || continue
            echo "    binary: ${binary#"$ARTIFACT"/}"
            codesign "${NESTED_ARGS[@]}" "$binary"
        done < <(find "$FRAMEWORKS" -type f -perm -u+x | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

        # Then bundles and libraries, innermost first. Symlinks are skipped: a framework's top-level
        # `Updater.app` is an alias into `Versions/B`, which is signed once, at its real path.
        while IFS= read -r nested; do
            [[ -n "$nested" ]] || continue
            echo "    bundle: ${nested#"$ARTIFACT"/}"
            codesign "${NESTED_ARGS[@]}" "$nested"
        done < <(find "$FRAMEWORKS" -depth ! -type l \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" -o -name "*.dylib" \))
    fi
fi

codesign "${SIGN_ARGS[@]}" "$ARTIFACT"
codesign --verify --deep --strict "$ARTIFACT"

# Check every binary the way the notary service will, before spending minutes on an upload.
# Each must carry the release identity and a secure timestamp; `codesign --verify` passes either
# way, which is exactly how the Autoupdate problem got as far as Apple.
if [[ "$ARTIFACT" == *.app ]]; then
    FAILURES=0
    while IFS= read -r binary; do
        file -b "$binary" | grep -q "Mach-O" || continue
        DETAILS="$(codesign -dvv "$binary" 2>&1)"
        if ! grep -q "^Authority=Developer ID Application" <<<"$DETAILS"; then
            echo "    NOT Developer ID signed: ${binary#"$ARTIFACT"/}" >&2
            FAILURES=$((FAILURES + 1))
        elif ! grep -q "^Timestamp=" <<<"$DETAILS"; then
            echo "    no secure timestamp: ${binary#"$ARTIFACT"/}" >&2
            FAILURES=$((FAILURES + 1))
        fi
    done < <(find "$ARTIFACT" -type f -perm -u+x)
    if (( FAILURES > 0 )); then
        echo "error: $FAILURES binaries would be rejected by notarization." >&2
        exit 1
    fi
    echo "    every binary is Developer ID signed with a secure timestamp"
fi
echo "==> Signed"
