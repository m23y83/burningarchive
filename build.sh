#!/bin/bash
# Builds BluRayBurner.app (release) with SwiftPM — Command Line Tools are enough, no Xcode needed.
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=(--arch arm64 --arch x86_64)   # universal: Apple Silicon + Intel
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/BluRayBurner"
APP="build/BluRayBurner.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BluRayBurner"
# Icon is generated from scripts/make-icon.swift; regenerate when the drawing changes.
if [ ! -f Resources/AppIcon.icns ] || [ scripts/make-icon.swift -nt Resources/AppIcon.icns ]; then
  scripts/make-icns.sh Resources
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BluRay Burner</string>
  <key>CFBundleDisplayName</key><string>BluRay Burner</string>
  <key>CFBundleIdentifier</key><string>io.github.m23y83.blurayburner</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>BluRayBurner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
