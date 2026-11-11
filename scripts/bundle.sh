#!/bin/zsh
# Build Cans.app (release, ad-hoc signed) into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Cans
BIN="$(swift build -c release --show-bin-path)/Cans"
APP=build/Cans.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Cans"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>        <string>dev.local.cans</string>
    <key>CFBundleName</key>              <string>Cans</string>
    <key>CFBundleExecutable</key>        <string>Cans</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Cans talks to your Bose headphones over Bluetooth to show battery and change modes.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
