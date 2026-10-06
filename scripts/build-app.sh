#!/bin/bash
# Builds build/FinderPin.app (menu-bar only, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/FinderPin"

if [ ! -f Resources/AppIcon.icns ]; then
    mkdir -p Resources build
    rm -rf build/AppIcon.iconset
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

APP=build/FinderPin.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FinderPin"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.finderpin</string>
    <key>CFBundleName</key><string>FinderPin</string>
    <key>CFBundleDisplayName</key><string>FinderPin</string>
    <key>CFBundleExecutable</key><string>FinderPin</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Signing identity: set FINDERPIN_SIGN_ID to a stable (e.g. self-signed) certificate so
# Accessibility / Screen Recording grants survive rebuilds. Ad-hoc ("-") changes the
# code hash on every build, which makes macOS forget the grants.
codesign --force --sign "${FINDERPIN_SIGN_ID:--}" --identifier local.finderpin "$APP"
echo "Built $APP"
