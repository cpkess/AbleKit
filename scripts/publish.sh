#!/bin/bash
#
# Publishes a built release to GitHub Releases.
#
# The appcast is attached to the release, and AbleKit's feed URL points at
# releases/latest/download/appcast.xml — so publishing is what makes an update visible to every
# installed copy. There is no separate update server to deploy.
#
# Usage: scripts/publish.sh <version> [dist-directory]
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: publish.sh <version> [dist-dir]}"
DIST="${2:-dist}"
TAG="v$VERSION"
DMG="$DIST/AbleKit-$VERSION.dmg"
APPCAST="$DIST/appcast.xml"

for required in "$DMG" "$APPCAST"; do
    if [[ ! -f "$required" ]]; then
        echo "error: $required is missing. Run 'make release VERSION=$VERSION' first." >&2
        exit 1
    fi
done

# Refusing to publish something Gatekeeper will reject is worth the extra second: an unnotarised
# DMG tells the people who download it that the app is damaged.
if ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    echo "error: $DMG is not notarised and stapled." >&2
    echo "       Anyone downloading it would be told the app is damaged. Run 'make notarize'." >&2
    exit 1
fi

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "error: release $TAG already exists." >&2
    echo "       Bump the version, or delete it with: gh release delete $TAG" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "warning: the working tree has uncommitted changes; they are not in this build." >&2
fi

echo "==> Tagging $TAG"
git tag -a "$TAG" -m "AbleKit $VERSION" 2>/dev/null || echo "    (tag already exists locally)"
git push origin "$TAG"

echo "==> Creating the release"
scripts/release-notes.sh "$VERSION" > "$DIST/notes.txt"
gh release create "$TAG" \
    --title "AbleKit $VERSION" \
    --notes-file "$DIST/notes.txt" \
    "$DMG" \
    "$APPCAST"

echo ""
echo "==> Published: $(gh release view "$TAG" --json url -q .url)"
echo "    Installed copies will see the update at their next check."
