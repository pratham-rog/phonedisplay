#!/bin/zsh
# Builds the free, unsigned/ad-hoc-signed release artifacts:
#   dist/PhoneDisplay-<version>-macOS.dmg
#   dist/PhoneDisplay-<version>-android.apk
# No Apple Developer account, notarization, App Store, or Play Store.
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
VERSION="${VERSION:-0.1.0}"
DIST="$ROOT/dist"
STAGE="$DIST/dmg-root"
APP="$ROOT/mac/PhoneDisplay/PhoneDisplay.app"
APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"

echo "==> macOS app"
(cd "$ROOT/mac/PhoneDisplay" && ./build.sh)

echo "==> Android APK"
(cd "$ROOT/android" && ./gradlew :app:assembleDebug)

echo "==> DMG"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/PhoneDisplay.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DIST/PhoneDisplay-$VERSION-macOS.dmg"
hdiutil create \
    -volname "PhoneDisplay" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DIST/PhoneDisplay-$VERSION-macOS.dmg" >/dev/null

echo "==> APK"
cp "$APK" "$DIST/PhoneDisplay-$VERSION-android.apk"

echo "==> checksums"
(cd "$DIST" && shasum -a 256 \
    "PhoneDisplay-$VERSION-macOS.dmg" \
    "PhoneDisplay-$VERSION-android.apk" > SHA256SUMS)

echo "✓ release artifacts:"
ls -lh "$DIST/PhoneDisplay-$VERSION-macOS.dmg" \
       "$DIST/PhoneDisplay-$VERSION-android.apk" \
       "$DIST/SHA256SUMS"
echo
echo "Install notes:"
echo "  macOS: open the DMG, drag PhoneDisplay to Applications, then"
echo "         System Settings → Privacy & Security → Open Anyway."
echo "  Android: allow install from the browser/file manager; the APK is"
echo "           signed with the local debug key and is not from Play Store."
