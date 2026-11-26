#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/build/MicroVol.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

swiftc -O \
    -framework Cocoa \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework IOKit \
    -framework ApplicationServices \
    "$ROOT_DIR/Sources/DDCController.swift" \
    "$ROOT_DIR/Sources/AudioManager.swift" \
    "$ROOT_DIR/Sources/MediaKeyInterceptor.swift" \
    "$ROOT_DIR/Sources/VolumeHUD.swift" \
    "$ROOT_DIR/Sources/main.swift" \
    -o "$MACOS_DIR/MicroVol"

cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"

echo "Built: $APP_DIR"
