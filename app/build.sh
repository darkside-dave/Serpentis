#!/bin/bash
set -euo pipefail
APP_ROOT=$(cd "$(dirname "$0")" && pwd)
APP_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/serpentis-build.XXXXXX")
trap 'rm -rf "$APP_BUILD"' EXIT
APP_BUNDLE="$APP_BUILD/Serpentis.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
if [ ! -f "$APP_ROOT/Resources/AppIcon.icns" ] || [ "$APP_ROOT/Resources/AppIcon.png" -nt "$APP_ROOT/Resources/AppIcon.icns" ]; then
    bash "$APP_ROOT/build-icon.sh"
fi
xcrun swiftc -O -swift-version 5 -file-prefix-map "$APP_ROOT=." \
    -module-cache-path "${TMPDIR:-/tmp}/serpentis-module-cache" \
    "$APP_ROOT"/Sources/*.swift -o "$APP_BUNDLE/Contents/MacOS/Serpentis"
cp "$APP_ROOT/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$APP_ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
codesign --force -s - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
mkdir -p "$APP_ROOT/build"
rm -rf "$APP_ROOT/build/Serpentis.app"
ditto "$APP_BUNDLE" "$APP_ROOT/build/Serpentis.app"
echo "Built: $APP_ROOT/build/Serpentis.app"
