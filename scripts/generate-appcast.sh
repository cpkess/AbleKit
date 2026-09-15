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

: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is not set}"

SIGN_UPDATE="$(find_sparkle_tool sign_update)"

# The key is handed over in a file rather than on the command line. Arguments are visible to every
# process on the machine via ps, which on a shared CI runner is a real exposure — and Sparkle now
# refuses the modern key format passed that way in any case.
KEY_FILE="$(mktemp)"
chmod 600 "$KEY_FILE"
trap 'rm -f "$KEY_FILE"' EXIT
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"

echo "==> Signing $(basename "$DMG")"
# sign_update prints an attribute fragment: sparkle:edSignature="..." length="..."
SIGNATURE_LINE="$("$SIGN_UPDATE" "$DMG" --ed-key-file "$KEY_FILE")"

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
