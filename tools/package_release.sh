#!/bin/zsh
# Builds the free, ad-hoc-signed macOS and release-signed Android artifacts:
#   dist/SpareScreen-<version>-macOS.dmg
#   dist/SpareScreen-<version>-android.apk
# No Apple Developer account, notarization, App Store, or Play Store.
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
VERSION="${VERSION:-0.1.1}"
DIST="$ROOT/dist"
STAGE="$DIST/dmg-root"
APP="$ROOT/mac/PhoneDisplay/SpareScreen.app"
KEYSTORE_PROPS="$ROOT/android/keystore.properties"
APK="$ROOT/android/app/build/outputs/apk/release/app-release.apk"

if [[ ! -f "$KEYSTORE_PROPS" ]]; then
    echo "Missing android/keystore.properties; release APK would be unsigned." >&2
    echo "Create it from your local release keystore (never commit it)." >&2
    exit 1
fi

echo "==> macOS app"
(cd "$ROOT/mac/PhoneDisplay" && ./build.sh)

echo "==> Android APK"
(cd "$ROOT/android" && ./gradlew :app:assembleRelease)

echo "==> DMG"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/SpareScreen.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DIST/SpareScreen-$VERSION-macOS.dmg"
hdiutil create \
    -volname "SpareScreen" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DIST/SpareScreen-$VERSION-macOS.dmg" >/dev/null

echo "==> APK"
cp "$APK" "$DIST/SpareScreen-$VERSION-android.apk"

echo "==> checksums"
(cd "$DIST" && shasum -a 256 \
    "SpareScreen-$VERSION-macOS.dmg" \
    "SpareScreen-$VERSION-android.apk" > SHA256SUMS)

echo "✓ release artifacts:"
ls -lh "$DIST/SpareScreen-$VERSION-macOS.dmg" \
       "$DIST/SpareScreen-$VERSION-android.apk" \
       "$DIST/SHA256SUMS"
echo
echo "Install notes:"
echo "  macOS: open the DMG, drag SpareScreen to Applications, then"
echo "         System Settings → Privacy & Security → Open Anyway."
echo "  Android: allow install from the browser/file manager; the APK is"
echo "           signed with the local release key and is not from Play Store."
