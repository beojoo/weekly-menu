#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Weekly Menu.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/.build/cache"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -module-cache-path "$ROOT/.build/cache" -file-prefix-map "$ROOT=." \
  "$ROOT/Sources/Usage.swift" "$ROOT/Sources/CodexTrust.swift" \
  "$ROOT/Sources/AppServer.swift" "$ROOT/Sources/main.swift" \
  -framework AppKit -framework SwiftUI -framework Security -framework ServiceManagement \
  -o "$APP/Contents/MacOS/WeeklyMenu"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier org.weeklymenu.app "$APP"
/usr/bin/codesign --verify --strict "$APP"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
printf '%s\n' "$APP"
