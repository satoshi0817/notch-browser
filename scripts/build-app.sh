#!/bin/zsh
# Builds NotchBrowser.app into ./build
#   --universal  also build for Intel and merge (for releases)
#   SIGNING_IDENTITY="Developer ID Application: ..." enables distribution signing
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/NotchBrowser.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "${1:-}" == "--universal" ]]; then
    swift build -c release --triple arm64-apple-macosx14.0
    swift build -c release --triple x86_64-apple-macosx14.0
    lipo -create -output "$APP/Contents/MacOS/NotchBrowser" \
        "$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)/NotchBrowser" \
        "$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)/NotchBrowser"
else
    swift build -c release
    cp "$(swift build -c release --show-bin-path)/NotchBrowser" "$APP/Contents/MacOS/NotchBrowser"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/NotchBrowser.icns "$APP/Contents/Resources/NotchBrowser.icns"
cp Resources/NotionAgentIcon-Light.png Resources/NotionAgentIcon-Dark.png "$APP/Contents/Resources/"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
        --entitlements Resources/NotchBrowser.entitlements "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
