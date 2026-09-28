#!/bin/zsh
# Builds NotchBrowser.app into ./build
#   --universal  also build for Intel and merge (for releases)
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
codesign --force --sign - "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
