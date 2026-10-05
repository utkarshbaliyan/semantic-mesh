#!/bin/bash
set -euo pipefail
APPLE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$APPLE_ROOT/.build/module-cache"
xcrun swiftc -swift-version 5 -D CORE_CHECKS -parse-as-library \
  -module-cache-path "$APPLE_ROOT/.build/module-cache" \
  "$APPLE_ROOT"/Core/*.swift "$APPLE_ROOT"/Tests/CoreTests.swift \
  -o "$APPLE_ROOT/.build/core-checks"
"$APPLE_ROOT/.build/core-checks"
