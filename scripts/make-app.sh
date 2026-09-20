#!/bin/sh
# Build a release Gowa.app bundle.
# Usage: scripts/make-app.sh [--open]
set -euo pipefail
cd "$(dirname "$0")/.."

APP=Gowa.app
IDENTIFIER=id.afrani.app.gowa
VERSION=3.0.0

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cp .build/release/gowa "$APP/Contents/MacOS/gowa"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>gowa</string>
    <key>CFBundleIdentifier</key>
    <string>$IDENTIFIER</string>
    <key>CFBundleName</key>
    <string>Gowa</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" Gowa.app.zip

echo "Built $APP ($(du -sh "$APP" | cut -f1)) and Gowa.app.zip"
if [ "${1:-}" = "--open" ]; then
    open "$APP"
fi
