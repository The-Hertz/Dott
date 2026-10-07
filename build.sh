#!/bin/sh
# Compila Dott e ne fa un'app: build/Dott.app
set -e
cd "$(dirname "$0")"
if [ -z "$SDKROOT" ] && [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
fi
swift build -c release
APP="build/Dott.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Dott "$APP/Contents/MacOS/Dott"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Dott</string>
  <key>CFBundleDisplayName</key><string>Dott</string>
  <key>CFBundleIdentifier</key><string>com.francesco.dott</string>
  <key>CFBundleExecutable</key><string>Dott</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Dott controlla se Music o Spotify stanno suonando, per ballare a tempo.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Fatto: $APP"
