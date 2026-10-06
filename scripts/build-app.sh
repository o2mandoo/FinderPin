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

# Signing identity. macOS ties Accessibility / Screen Recording grants to the app's
# designated requirement. Ad-hoc ("-") pins it to the code hash, which changes on every
# build and makes macOS forget the grants; a stable certificate keeps them.
# Default: the "FinderPin Self-Signed" identity if it is in the keychain
# (see scripts/make-signing-cert.sh), otherwise ad-hoc. Override with FINDERPIN_SIGN_ID.
SIGN_ID="${FINDERPIN_SIGN_ID:-$(security find-identity -p codesigning | awk '/"FinderPin Self-Signed"/{print $2; exit}')}"
codesign --force --sign "${SIGN_ID:--}" --identifier local.finderpin "$APP"
codesign -dr - "$APP" 2>&1 | tail -1
echo "Built $APP"
