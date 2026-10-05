#!/bin/bash
set -euo pipefail
APPLE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/semanticmesh-mac.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT
APP_PATH="$BUILD_ROOT/Semantic Mesh.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APPLE_ROOT/.build/module-cache" "$APPLE_ROOT/output"
ARCH="$(uname -m)"
xcrun swiftc -swift-version 5 -target "$ARCH-apple-macosx14.0" -parse-as-library \
  -module-cache-path "$APPLE_ROOT/.build/module-cache" \
  "$APPLE_ROOT"/Core/*.swift "$APPLE_ROOT"/App/*.swift \
  -o "$APP_PATH/Contents/MacOS/SemanticMeshMac"
cp "$APPLE_ROOT/App/MacInfo.plist" "$APP_PATH/Contents/Info.plist"
# Sign outside synced folders, whose Finder metadata can interrupt code signing.
xattr -cr "$APP_PATH"
codesign --force --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
ditto -c -k --norsrc --keepParent "$APP_PATH" "$APPLE_ROOT/output/SemanticMesh-Mac.zip"
ditto --norsrc --noextattr "$APP_PATH" "$APPLE_ROOT/output/Semantic Mesh.app"
printf 'Built %s\n' "$APPLE_ROOT/output/Semantic Mesh.app"
