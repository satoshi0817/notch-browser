#!/bin/zsh
# Builds a universal NotchBrowser.app and zips it for a GitHub release.
#   scripts/release.sh            -> build/NotchBrowser-<version>.zip
#   scripts/release.sh --publish  -> also tags v<version> and creates the GitHub release
#   --notarize <keychain-profile> -> notarize and staple before packaging
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLISH=false
NOTARY_PROFILE=""
while (( $# > 0 )); do
    case "$1" in
        --publish) PUBLISH=true; shift ;;
        --notarize)
            if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then
                echo "--notarize requires a notarytool keychain profile." >&2
                exit 1
            fi
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done
if [[ "$PUBLISH" == true && -z "$NOTARY_PROFILE" ]]; then
    echo "Publishing requires --notarize <keychain-profile>." >&2
    exit 1
fi
if [[ -n "$NOTARY_PROFILE" ]]; then
    if [[ "${SIGNING_IDENTITY:-}" != "Developer ID Application:"* ]]; then
        echo "Set SIGNING_IDENTITY to your Developer ID Application certificate name." >&2
        exit 1
    fi
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
ZIP="build/NotchBrowser-$VERSION.zip"

./scripts/build-app.sh --universal
rm -f "$ZIP"
# ditto keeps the bundle's signature and extended attributes intact.
ditto -c -k --sequesterRsrc --keepParent build/NotchBrowser.app "$ZIP"
if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" \
        --wait --output-format json > build/notarization-result.json
    if [[ "$(/usr/bin/plutil -extract status raw -o - build/notarization-result.json)" != "Accepted" ]]; then
        echo "Notarization was not accepted; see build/notarization-result.json." >&2
        exit 1
    fi
    xcrun stapler staple build/NotchBrowser.app
    xcrun stapler validate build/NotchBrowser.app
    spctl --assess --type execute --verbose=2 build/NotchBrowser.app
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent build/NotchBrowser.app "$ZIP"
fi
echo "Packaged $ZIP ($(du -h "$ZIP" | cut -f1))"

if [[ "$PUBLISH" == true ]]; then
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "Working tree has uncommitted changes; commit before publishing." >&2
        exit 1
    fi
    git tag -a "v$VERSION" -m "NotchBrowser $VERSION"
    git push origin HEAD:main "v$VERSION"
    gh release create "v$VERSION" "$ZIP" --title "NotchBrowser $VERSION" --notes-file scripts/release-notes.md
fi
