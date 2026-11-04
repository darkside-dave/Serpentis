#!/bin/bash
set -euo pipefail
APP_ROOT=$(cd "$(dirname "$0")" && pwd)
ICON_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/serpentis-icon.XXXXXX")
trap 'rm -rf "$ICON_BUILD"' EXIT
ICONSET="$ICON_BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$APP_ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$APP_ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_ROOT/Resources/AppIcon.icns"
