#!/bin/bash
# Builds VibeCheck.app (a proper menu-bar-only app bundle) into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh

APP=build/VibeCheck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp build/VibeCheck "$APP/Contents/MacOS/VibeCheck"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.lumx.vibecheck</string>
    <key>CFBundleName</key>
    <string>VibeCheck</string>
    <key>CFBundleDisplayName</key>
    <string>VibeCheck</string>
    <key>CFBundleExecutable</key>
    <string>VibeCheck</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

echo "Built $APP"
echo "Run it with: open $APP"
