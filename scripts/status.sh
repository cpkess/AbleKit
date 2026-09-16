#!/bin/bash
#
# Reports the state of everything that is easy to get wrong: signing, install location, the
# permission-relevant designated requirement, and whether updates are actually configured.
#
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.ablekit.AbleKit"
INSTALLED="/Applications/AbleKit.app"

echo "AbleKit status"
echo "=============="
echo ""

echo "Toolchain"
echo "  Xcode        $(xcodebuild -version 2>/dev/null | head -1 | cut -d' ' -f2)"
echo "  macOS SDK    $(xcrun --sdk macosx --show-sdk-version 2>/dev/null)"
echo "  Swift        $(swift --version 2>&1 | grep -o 'Swift version [0-9.]*' | cut -d' ' -f3)"
echo ""

echo "Installed app"
if [[ -d "$INSTALLED" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INSTALLED/Contents/Info.plist" 2>/dev/null || echo "?")"
    BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INSTALLED/Contents/Info.plist" 2>/dev/null || echo "?")"
    echo "  Location     $INSTALLED"
    echo "  Version      $VERSION ($BUILD)"
    TEAM="$(codesign -dv --verbose=2 "$INSTALLED" 2>&1 | grep TeamIdentifier | cut -d= -f2)"
    echo "  Team         ${TEAM:-not set}"

    # A designated requirement containing a hash means TCC will forget the app on every rebuild,
    # which is the failure that looks like "I granted permission and nothing happened".
    if codesign -d -r- "$INSTALLED" 2>&1 | grep -q "cdhash"; then
        echo "  Signing      AD-HOC — permissions will be forgotten on every rebuild"
    else
        echo "  Signing      stable (grants survive rebuilds)"
    fi

    if pgrep -f "AbleKit.app/Contents/MacOS/AbleKit" >/dev/null; then
        echo "  Running      yes"
    else
        echo "  Running      no"
    fi
else
    echo "  Not installed. Run 'make run'."
fi
echo ""

echo "Permissions"
# Read from the app's own perspective is impossible from here, so this reports what can be seen:
# whether macOS has a record of the app at all.
echo "  Accessibility and Screen Recording are per-app grants that only the app itself can query."
echo "  AbleKit shows them live in its onboarding window; 'make permissions' opens the panes."
echo ""

echo "Updates"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Configs/Info.plist 2>/dev/null || echo "")"
if [[ -n "$PUBLIC_KEY" ]]; then
    echo "  Signing key  configured (${PUBLIC_KEY:0:16}…)"
else
    echo "  Signing key  NOT SET — builds cannot receive updates. Run 'make sparkle-keys'."
fi
FEED="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" Configs/Info.plist 2>/dev/null || echo "")"
echo "  Feed         ${FEED:-not set}"
echo ""

echo "Release credentials"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')"
    echo "  Signing      $IDENTITY"
else
    echo "  Signing      no Developer ID certificate — 'make dmg' will fail"
fi
if xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-AbleKit}" >/dev/null 2>&1; then
    echo "  Notarizing   stored profile '${NOTARY_PROFILE:-AbleKit}' works"
else
    echo "  Notarizing   NOT SET UP — see 'make notarize' for the one-time setup"
fi
