#!/bin/bash
#
# Locates the Sparkle command-line tools that ship inside the resolved Swift package.
#
# Sourced by the other scripts rather than duplicated, because the path depends on where packages
# were cloned and that differs between a local checkout and CI.
#
set -euo pipefail

find_sparkle_tool() {
    local tool="$1"
    local root="${SPM_CACHE_DIR:-.build/spm}"

    local found
    found="$(find "$root" -type f -name "$tool" -path "*/artifacts/*/bin/*" -perm -u+x 2>/dev/null | head -1)"
    if [[ -z "$found" ]]; then
        # Fall back to Xcode's default clone location for a local build that did not pass
        # -clonedSourcePackagesDirPath.
        found="$(find ~/Library/Developer/Xcode/DerivedData -type f -name "$tool" \
            -path "*/SourcePackages/artifacts/*/bin/*" -perm -u+x 2>/dev/null | head -1)"
    fi
    if [[ -z "$found" ]]; then
        echo "error: could not find Sparkle's $tool. Resolve packages first:" >&2
        echo "  xcodebuild -resolvePackageDependencies -project AbleKit.xcodeproj -clonedSourcePackagesDirPath .build/spm" >&2
        return 1
    fi
    echo "$found"
}
