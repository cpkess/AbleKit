#!/bin/bash
#
# Builds AbleKit-<version>.dmg: a single window holding AbleKit.app next to an Applications
# alias, which is the installation gesture every Mac user already knows.
#
# Usage: scripts/build-dmg.sh <path-to-AbleKit.app> <version> [output-directory]
#
set -euo pipefail

APP_PATH="${1:?usage: build-dmg.sh <app> <version> [outdir]}"
VERSION="${2:?usage: build-dmg.sh <app> <version> [outdir]}"
OUTPUT_DIR="${3:-dist}"

APP_NAME="$(basename "$APP_PATH")"
VOLUME_NAME="AbleKit ${VERSION}"
DMG_PATH="${OUTPUT_DIR}/AbleKit-${VERSION}.dmg"
STAGING_DIR="$(mktemp -d)"

cleanup() {
    # A staging directory left behind on failure would be attached on the next run.
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: $APP_PATH does not exist" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$DMG_PATH"

echo "==> Staging $APP_NAME"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# A background image and window geometry would need a mounted read-write image and AppleScript to
# position icons. That is a lot of fragile machinery for a cosmetic gain, and it breaks on headless
# CI runners where no Finder session exists. A clean two-icon window is the durable choice.
echo "==> Creating $DMG_PATH"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    -quiet \
    "$DMG_PATH"

echo "==> Built $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
