#!/bin/zsh
# Builds the PhoneDisplay macOS host helper. Requires only Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

SDK=$(xcrun --show-sdk-path)

clang \
  -fobjc-arc -fblocks -O2 -Wall \
  -isysroot "$SDK" \
  -mmacosx-version-min=12.3 \
  -framework Foundation -framework CoreGraphics -framework CoreMedia \
  -framework CoreVideo -framework VideoToolbox -framework ScreenCaptureKit \
  -o vdhelper vdhelper.m

# App bundle with the same (copied) binary. Exists so the Accessibility
# permission picker can select a real .app; the copy keeps the exact same
# bytes/cdhash as the raw binary, so grants match either way.
APP=vdhelper.app
mkdir -p "$APP/Contents/MacOS"
cp -f vdhelper "$APP/Contents/MacOS/vdhelper"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.phonedisplay.vdhelper</string>
    <key>CFBundleName</key><string>vdhelper</string>
    <key>CFBundleExecutable</key><string>vdhelper</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSBackgroundOnly</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign the bundle so its identity is stable across rebuilds. (Click
# injection permission lives with the hosting terminal, not with this binary,
# so re-signing does not invalidate the grant.)
codesign --force --deep --sign - --identifier dev.phonedisplay.vdhelper "$APP" >/dev/null 2>&1 || true

echo "✓ built: $(pwd)/vdhelper  (+ $APP bundle for permissions)"
echo "  display only:  ./vdhelper --display-only --seconds 15"
echo "  stream mode :  ./vdhelper --stream | head -c 1000000 > test.h264"
