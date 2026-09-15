#!/bin/bash
#
# Creates the EdDSA key pair Sparkle uses to prove an update really came from this project.
#
# Run this ONCE, on a trusted machine. The private key is stored in the login keychain and must
# never be committed; the release workflow reads it from a repository secret. Losing it means no
# existing installation can ever be updated again, so back it up somewhere durable.
#
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sparkle-tools.sh

GENERATE_KEYS="$(find_sparkle_tool generate_keys)"

echo "==> Generating a Sparkle signing key pair"
"$GENERATE_KEYS"

cat <<'NOTE'

Next steps
----------
1. Copy the public key printed above into Configs/Info.plist, as the value of SUPublicEDKey.
   Until it is set, AbleKit refuses every update — which is the correct default, not a bug.

2. Export the private key and store it as the repository secret SPARKLE_PRIVATE_KEY:

       ./scripts/generate-keys.sh --export

3. Back the private key up somewhere you will still have in five years.

NOTE

if [[ "${1:-}" == "--export" ]]; then
    "$GENERATE_KEYS" -x /dev/stdout
fi
