#!/bin/bash
# Builds VibeCheck.app (a proper menu-bar-only app bundle) into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.2.0"

./scripts/build.sh

APP=build/VibeCheck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/VibeCheck "$APP/Contents/MacOS/VibeCheck"

# The icon is rendered from the same pixel-art code as the runners, so no
# binary asset is checked in and the icon can never drift from the sprites.
if ./build/VibeCheck --dump-iconset build/AppIcon.iconset >/dev/null 2>&1 \
   && iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null
then
  ICON_KEY='    <key>CFBundleIconFile</key>
    <string>AppIcon</string>'
else
  echo "note: could not render the app icon; building without one" >&2
  ICON_KEY=''
fi

cat > "$APP/Contents/Info.plist" <<PLIST
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
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
$ICON_KEY
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# "Open at login" (SMAppService) only works for a signed bundle; an ad-hoc
# signature is enough for a locally built app and costs nothing.
codesign --force --sign - "$APP" >/dev/null 2>&1 \
  || echo "note: could not ad-hoc sign the bundle; 'Open at login' may be unavailable" >&2

echo "Built $APP (${VERSION})"
echo "Run it with: open $APP"
