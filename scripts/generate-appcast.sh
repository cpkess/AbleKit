#!/bin/bash
#
# Writes the appcast that tells installed copies of AbleKit an update exists.
#
# Every entry carries an EdDSA signature over the download. Sparkle verifies it before the update
# is unpacked, which is what stops a compromised release host — or anything between it and the
# user — from shipping arbitrary code to every installation.
#
# Usage: scripts/generate-appcast.sh <dmg> <version> <build> <release-notes-file> [output]
#
# Requires SPARKLE_PRIVATE_KEY in the environment (the key from scripts/generate-keys.sh).
#
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sparkle-tools.sh

DMG="${1:?usage: generate-appcast.sh <dmg> <version> <build> <notes> [output]}"
VERSION="${2:?}"
BUILD="${3:?}"
NOTES_FILE="${4:?}"
OUTPUT="${5:-dist/appcast.xml}"

SIGN_UPDATE="$(find_sparkle_tool sign_update)"

echo "==> Signing $(basename "$DMG")"
# Two ways in, depending on where this runs.
#
# Locally the key lives in the login keychain, which is where generate_keys put it, and nothing
# needs to be handed around at all. On CI there is no keychain, so the key arrives as a secret and
# is written to a mode-600 file — never passed as an argument, because arguments are visible to
# every process on the machine through ps.
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    KEY_FILE="$(mktemp)"
    chmod 600 "$KEY_FILE"
    trap 'rm -f "$KEY_FILE"' EXIT
    printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"
    SIGNATURE_LINE="$("$SIGN_UPDATE" "$DMG" --ed-key-file "$KEY_FILE")"
else
    if ! SIGNATURE_LINE="$("$SIGN_UPDATE" "$DMG" 2>&1)"; then
        echo "error: could not sign the update." >&2
        echo "       No SPARKLE_PRIVATE_KEY was set and the login keychain holds no Sparkle key." >&2
        echo "       Run 'make sparkle-keys' once to create one." >&2
        exit 1
    fi
fi

DOWNLOAD_URL="https://github.com/cpkess/AbleKit/releases/download/v${VERSION}/$(basename "$DMG")"
PUBLISHED="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

# Release notes are embedded rather than linked so the update dialog works offline and cannot be
# changed after the signature was made.
NOTES_HTML="$(python3 - "$NOTES_FILE" <<'PY'
import html, sys
text = open(sys.argv[1]).read().strip()
paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]
print("".join(f"<p>{html.escape(p)}</p>" for p in paragraphs))
PY
)"

mkdir -p "$(dirname "$OUTPUT")"
cat > "$OUTPUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>AbleKit</title>
        <link>https://github.com/cpkess/AbleKit/releases/latest/download/appcast.xml</link>
        <description>Updates for AbleKit</description>
        <language>en</language>
        <item>
            <title>AbleKit ${VERSION}</title>
            <pubDate>${PUBLISHED}</pubDate>
            <sparkle:version>${BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
            <description><![CDATA[${NOTES_HTML}]]></description>
            <enclosure url="${DOWNLOAD_URL}" type="application/octet-stream" ${SIGNATURE_LINE} />
        </item>
    </channel>
</rss>
XML

echo "==> Wrote $OUTPUT"
