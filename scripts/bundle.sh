#!/bin/zsh
# Build Cans.app (release, universal, ad-hoc signed) into ./build.
# Usage: scripts/bundle.sh [version]   (default: latest git tag, else 0.0.0)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
ARCHS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCHS[@]}" --product Cans
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Cans"
APP=build/Cans.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cans"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>        <string>io.github.egno.cans</string>
    <key>CFBundleName</key>              <string>Cans</string>
    <key>CFBundleDisplayName</key>       <string>Cans</string>
    <key>CFBundleExecutable</key>        <string>Cans</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string>MIT License</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Cans talks to your Bose headphones over Bluetooth to show battery and change modes.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP $VERSION ($BUILD_NUMBER) [$(lipo -archs "$APP/Contents/MacOS/Cans")]"
