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
    ICON_INPUT="$icon_source" ICON_OUTPUT="$padded_icon" swift - <<'SWIFT'
import AppKit
import Foundation

let environment = ProcessInfo.processInfo.environment
guard
    let inputPath = environment["ICON_INPUT"],
    let outputPath = environment["ICON_OUTPUT"],
    let sourceImage = NSImage(contentsOfFile: inputPath)
else {
    fputs("Failed to load icon source\n", stderr)
    exit(1)
}

let canvasSize = NSSize(width: 1024, height: 1024)
let insetScale: CGFloat = 0.82
let scaledSize = NSSize(
    width: canvasSize.width * insetScale,
    height: canvasSize.height * insetScale
)
let origin = NSPoint(
    x: (canvasSize.width - scaledSize.width) / 2,
    y: (canvasSize.height - scaledSize.height) / 2
)

guard let representation = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Failed to create icon canvas\n", stderr)
    exit(1)
}

representation.size = canvasSize
NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
    fputs("Failed to create graphics context\n", stderr)
    exit(1)
}
NSGraphicsContext.current = context
NSColor.clear.setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: canvasSize)).fill()
sourceImage.draw(in: NSRect(origin: origin, size: scaledSize))
NSGraphicsContext.restoreGraphicsState()

guard let pngData = representation.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode icon\n", stderr)
    exit(1)
}

try pngData.write(to: URL(fileURLWithPath: outputPath))
SWIFT
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
