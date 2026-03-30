#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="YouTube4Mac"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
SOURCE_FILE="$ROOT_DIR/Sources/YouTube4Mac/main.swift"
ICON_SOURCE_FILE="$ROOT_DIR/Assets/AppIcon.svg"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TMP_DIR="$(mktemp -d)"
export ICON_SOURCE_FILE

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

extract_icon_png() {
    TMP_ICON_SOURCE="$TMP_DIR/icon-source.png" python3 - <<'PY'
import base64
import os
import pathlib
import re

svg = pathlib.Path(os.environ["ICON_SOURCE_FILE"]).read_text()
match = re.search(r'base64,([^"\']+)', svg)
if match is None:
    raise SystemExit("Could not find embedded PNG data in icon SVG")

path = pathlib.Path(os.environ["TMP_ICON_SOURCE"])
path.write_bytes(base64.b64decode(match.group(1)))
PY
}

build_iconset() {
    local icon_source="$TMP_DIR/icon-source.png"
    local padded_icon="$RESOURCES_DIR/AppIcon.png"

    extract_icon_png
    sips -p 1024 1024 --padColor 000000 "$icon_source" --out "$padded_icon" >/dev/null
}

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>YouTube4Mac</string>
    <key>CFBundleIdentifier</key>
    <string>com.youtube4mac.app</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>YouTube4Mac</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

build_iconset

xcrun swiftc \
    -parse-as-library \
    -target arm64-apple-macos14.0 \
    -sdk "$SDK_PATH" \
    -framework AppKit \
    -framework SwiftUI \
    -framework WebKit \
    "$SOURCE_FILE" \
    -o "$MACOS_DIR/$APP_NAME"

echo "Built $APP_DIR"
