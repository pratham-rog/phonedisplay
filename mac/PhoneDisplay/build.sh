#!/bin/zsh
# Builds PhoneDisplay.app with Command Line Tools only. No Xcode project.
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(pwd)"
APP="$ROOT/PhoneDisplay.app"
HELPER_SRC="$ROOT/../../host-macos"

echo "==> core checks"
swift run -c release PhoneDisplayCoreChecks

echo "==> app"
swift build -c release --product PhoneDisplay

echo "==> helper"
(cd "$HELPER_SRC" && ./build.sh)

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$ROOT/.build/release/PhoneDisplay" "$APP/Contents/MacOS/PhoneDisplay"
cp "$HELPER_SRC/vdhelper" "$APP/Contents/Helpers/vdhelper"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.phonedisplay.app</string>
    <key>CFBundleName</key><string>PhoneDisplay</string>
    <key>CFBundleDisplayName</key><string>PhoneDisplay</string>
    <key>CFBundleExecutable</key><string>PhoneDisplay</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>PhoneDisplay needs the local network to connect your phone.</string>
    <key>NSHumanReadableCopyright</key><string>PhoneDisplay</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - --identifier dev.phonedisplay.helper "$APP/Contents/Helpers/vdhelper" >/dev/null
codesign --force --deep --sign - --identifier dev.phonedisplay.app "$APP" >/dev/null

echo "✓ built: $APP"
echo "  run:   open \"$APP\""
echo "  check: codesign -dv \"$APP\""
