#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/NotchBrowserDesignPreview.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier com.satoshi0817.NotchBrowser.DesignPreview' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleDisplayName NotchBrowser Design Preview' "$APP/Contents/Info.plist"
cp Resources/NotchBrowser.icns "$APP/Contents/Resources/"
SOURCES=(Sources/NotchBrowser/*.swift)
SOURCES=(${SOURCES:#Sources/NotchBrowser/main.swift})
swiftc -o "$APP/Contents/MacOS/NotchBrowser" "${SOURCES[@]}" scripts/DesignPreview.swift
codesign --force --sign - "$APP"
cat > build/preview-page.html <<'HTML'
<!doctype html><meta charset="utf-8"><title>Preview workspace</title>
<style>body{font:16px -apple-system;background:#f4f7fc;color:#22304b;padding:40px}small{color:#687990}h1{font-size:32px}article{padding:24px;border-radius:20px;background:white;margin-top:24px}p{line-height:1.8}</style>
<small>NOTCHBROWSER / LOCAL PREVIEW</small><h1>小さなブラウザ、大きな余白。</h1>
<article><h2>いつもの作業を、すぐそばに。</h2><p>これは画面確認用のローカルページです。検索、拡大縮小、タブ切り替えをここで確認できます。</p><p>Find this phrase: Liquid Glass.</p></article>
HTML
open -n "$APP" --args "$PWD/build/preview-page.html" "$@"
