#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build/cache"
xcrun swiftc -swift-version 5 -module-cache-path "$ROOT/.build/cache" -file-prefix-map "$ROOT=." \
 "$ROOT/Sources/Usage.swift" "$ROOT/Sources/CodexTrust.swift" \
 "$ROOT/Sources/AppServer.swift" "$ROOT/Tests/Tests.swift" \
 -framework Security -o "$ROOT/.build/WeeklyMenuTests"
"$ROOT/.build/WeeklyMenuTests" "$@"
