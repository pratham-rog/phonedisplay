# PhoneDisplay

Use an Android phone as a real second display for a Mac. Free, local-only, no
accounts, no cloud, no App Store or Play Store.

- **Mac:** native SwiftUI app around a small Objective-C/ScreenCaptureKit
  helper (`vdhelper`). Creates a virtual display and hardware-encodes H.264.
- **Android:** native Kotlin app. Pairs over USB, pins the Mac's TLS
  certificate, hardware-decodes H.264, and renders fullscreen.
- **Transport:** TLS 1.2+ over the USB loopback link, with a one-time
  ADB-delivered pairing token and a separate per-phone device secret.

The secure host and Android client are implemented and tested on a Galaxy S24
Ultra (SM-S928B). USB is the supported path in this release; Wi-Fi is deferred.

## Requirements

- macOS 14 or newer. Apple Silicon is the primary target; Intel is best effort.
- Android 8.0 (API 24) or newer.
- A USB data cable and **USB debugging** enabled on the phone.
- `adb` on the Mac: Android platform-tools, Android Studio, or Homebrew.

No same-Wi-Fi requirement and no QR scanner are needed.

## Build and run the Mac app

```sh
cd mac/PhoneDisplay
./build.sh
open PhoneDisplay.app
```

The app is ad-hoc signed and not notarized. A downloaded build needs
**System Settings → Privacy & Security → Open Anyway**. On first run grant:

1. **Screen Recording** — required to capture the virtual display.
2. **Accessibility** — required for clicks and S-Pen input; pointer movement
   works without it.
3. **Local Network** — only if macOS asks when the listener starts; USB does
   not use it.

Press **Start PhoneDisplay**, choose a display profile, then connect the phone
by USB. The Mac finds the authorized ADB device, sets up `adb reverse`, and
sends a one-time pairing intent. The Android app opens and pairs automatically.

## Build and install the Android app

```sh
cd android
./gradlew :app:assembleRelease
# APK: app/build/outputs/apk/release/app-release.apk
```

Install it on the phone (enable "install unknown apps" for the file manager or
browser you use). The release APK is signed with the local release key; it is
not a Play Store build. If an earlier debug-signed build is installed, uninstall
it first: Android will not update across a signing-key change. Release builds
require the git-ignored `android/keystore.properties` described under
**Release packaging**.

When the phone is reachable over USB:

```sh
adb install -r android/app/build/outputs/apk/release/app-release.apk
```

## Pairing over USB

1. Enable **Developer options → USB debugging** on the phone and authorize the
   Mac when prompted.
2. Connect the phone by USB and press **Start PhoneDisplay** on the Mac.
3. The Mac runs `adb reverse tcp:8420 tcp:8420` and pushes a base64 pairing
   intent with
   `adb shell am start -n dev.phonedisplay.app/.MainActivity --es pd_pairing_b64 <payload>`.
4. The Android app connects to `127.0.0.1:8420`, pins the Mac certificate, and
   receives a per-phone device secret.
5. Later launches reconnect with that secret; press **Connect** on the phone if
   the stream was stopped.

The one-time token expires after two minutes and can pair one phone. The
long-lived secret is issued only after a successful TLS connection and is
stored in the Android Keystore (AES-GCM) and in a 0600 file on the Mac. The app
enforces one active phone: a second phone gets a clear "already in use" error,
while the same phone can replace its own old session.

The Mac refreshes the ADB reverse mapping every 5 seconds. If the listener
falls back to another port (8421–8439), the reverse mapping and pairing intent
use that port automatically.

If `adb devices` shows `unauthorized`, unlock the phone and accept the USB
debugging prompt, then press **Send pairing again**.

## Display profiles

- **Universal — 1920×1080 at 60 fps** (default, ~10 Mbps).
- **Galaxy S24 — 3120×1440 at 90 fps** (~20 Mbps).

The profile is chosen on the Mac before starting. The phone follows the Mac's
stream rate on first run; the in-app 60/90 pill overrides it and is remembered.
While streaming, tap the top-left corner (or use the pen) to reveal the pill.

The stream fills the phone screen. At the 60 profile the 16:9 image is scaled
to 3120×1440 and the top and bottom are center-cropped; at the 90 profile it
fills exactly. The menu bar and Dock can be cut at the 60 profile.

## Security model

- Self-signed P-256 TLS identity generated on the Mac and stored 0600.
- The one-time pairing payload is delivered over the authorized USB/ADB link;
  it carries the certificate SHA-256 fingerprint. Android refuses any other
  certificate. No plaintext token or video is sent.
- Pairing token: 32 random bytes, one use, two-minute expiry.
- Device secret: 32 random bytes, per phone, revocable by re-pairing.
- One active phone at a time.
- Heartbeat every 5 seconds; a silent client is dropped after 15 seconds.
- The virtual display and helper stop after 10 seconds without an active phone.
- Mac sleep, display sleep, and screen lock pause the stream and release the
  virtual display; the phone reconnects after wake/unlock.
- On a static Mac screen, a reconnecting phone receives the last encoded
  keyframe so it does not stay black waiting for a screen change.
- Never share `host-macos/stream.log`: it may contain a legacy token. The secure
  app does not print the pairing token or device secret.

## Developer harness

The Python TLS client is for testing without a phone:

```sh
# Mac app must be running with PHONEDISPLAY_DEV=1 (writes dev-pairing.json 0600)
cd mac/PhoneDisplay
PHONEDISPLAY_DEV=1 PHONEDISPLAY_SYNTHETIC=1 ./PhoneDisplay.app/Contents/MacOS/PhoneDisplay --autostart

# in another terminal
python3 tools/testclient_tls.py 8
```

It verifies the certificate fingerprint, pairs once, reconnects with the stored
device secret, sends heartbeats, and prints stream statistics. It never prints
the token or secret.

The old `host-macos/pdctl.py` / `tools/testclient.py` plain-TCP harness remains
only for the legacy helper workflow and does not speak to the secure Mac app.

## Release packaging

```sh
VERSION=0.1.0 ./tools/package_release.sh
```

Produces:

```
dist/PhoneDisplay-0.1.0-macOS.dmg
dist/PhoneDisplay-0.1.0-android.apk
dist/SHA256SUMS
```

Upload those three files to a GitHub Release. The DMG is ad-hoc signed; the APK
is signed with the local release key. See `RELEASE.md` for the
download/install text. Set `JAVA_HOME` to a JDK 17 if Gradle or `apksigner`
cannot find Java.

`android/keystore.properties` is required for release builds and is never
committed. Back up both that file and the referenced keystore: losing the key
means existing installs cannot receive updates without uninstalling and
re-pairing.

## License

MIT — see [LICENSE](LICENSE).

## Current limits

- Tested on a Galaxy S24 Ultra (SM-S928B): USB pairing, TLS, 1080p60,
  1440p90, reverse recovery, idle teardown, relaunch/reconnect, and permissions.
- Physical S-Pen hover, tap, right-click, and 3× cursor still need a hands-on
  check. Synthetic stylus injection enters pen mode.
- Wi-Fi is deferred; USB is the only supported transport in this release.
- The macOS 14 TLS identity ACL fallback compiles but was not tested on macOS 14.
- No Bonjour discovery; USB pairing is automatic after the first connection.
- No Windows host yet.
- The macOS 27 fullscreen-Space bug is an OS bug; move a normal window to the
  phone display and fullscreen it there.

## Repository layout

```
mac/PhoneDisplay/   SwiftUI app, TLS host, pairing, helper lifecycle
android/            Kotlin Android client
host-macos/         vdhelper + legacy Python host harness
tools/              TLS test client, release packaging
docs/               product design and implementation notes
```
