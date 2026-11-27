#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/build/MicroVol.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

swiftc -O \
    -target arm64-apple-macos13.0 \
    -framework Cocoa \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework IOKit \
    -framework ApplicationServices \
    -framework ServiceManagement \
    "$ROOT_DIR/Sources/DDCController.swift" \
    "$ROOT_DIR/Sources/AudioManager.swift" \
    "$ROOT_DIR/Sources/MediaKeyInterceptor.swift" \
    "$ROOT_DIR/Sources/VolumeHUD.swift" \
    "$ROOT_DIR/Sources/main.swift" \
    -o "$MACOS_DIR/MicroVol"

cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi
codesign --force --deep --sign - "$APP_DIR"

echo "Built: $APP_DIR"
