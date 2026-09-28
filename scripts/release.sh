#!/bin/zsh
# Builds a universal NotchBrowser.app and zips it for a GitHub release.
#   scripts/release.sh            -> build/NotchBrowser-<version>.zip
#   scripts/release.sh --publish  -> also tags v<version> and creates the GitHub release
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
ZIP="build/NotchBrowser-$VERSION.zip"

./scripts/build-app.sh --universal
rm -f "$ZIP"
# ditto keeps the bundle's signature and extended attributes intact.
ditto -c -k --sequesterRsrc --keepParent build/NotchBrowser.app "$ZIP"
echo "Packaged $ZIP ($(du -h "$ZIP" | cut -f1))"

if [[ "${1:-}" == "--publish" ]]; then
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "Working tree has uncommitted changes; commit before publishing." >&2
        exit 1
    fi
    git tag -a "v$VERSION" -m "NotchBrowser $VERSION"
    git push origin main "v$VERSION"
    gh release create "v$VERSION" "$ZIP" --title "NotchBrowser $VERSION" --notes-file scripts/release-notes.md
fi
