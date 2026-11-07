# PhoneDisplay

Use an Android phone as a real second display for a Mac. Free, local-only, no
accounts, no cloud, no App Store or Play Store.

- **Mac:** native SwiftUI app around a small Objective-C/ScreenCaptureKit
  helper (`vdhelper`). Creates a virtual display and hardware-encodes H.264.
- **Android:** native Kotlin app. Scans the Mac's QR, pins the Mac's TLS
  certificate, hardware-decodes H.264, and renders fullscreen.
- **Transport:** TLS 1.2+ on the local network, with a one-time QR bootstrap
  token and a separate per-phone device secret.

The previous plain-TCP prototype is no longer used by the app. The secure host
and Android client are implemented; the next physical-device test is installing
the APK and scanning the Mac QR.

## Requirements

- macOS 14 or newer. Apple Silicon is the primary target; Intel is best effort.
- Android 8.0 (API 24) or newer.
- Mac and phone on the same Wi-Fi network for the normal path.
- USB is supported as an advanced fallback with `adb reverse`; see below.

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
3. **Local Network** — only if macOS asks when the listener starts.

Press **Start PhoneDisplay**, choose a display profile, then scan the QR with
the Android app.

## Build and install the Android app

```sh
cd android
./gradlew :app:assembleDebug
# APK: app/build/outputs/apk/debug/app-debug.apk
```

Install it on the phone (enable "install unknown apps" for the file manager or
browser you use). The debug APK is signed with the local Android debug key; it
is not a Play Store build.

When the phone is reachable over USB:

```sh
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

## Pairing

1. Mac: press **Start PhoneDisplay**. A QR appears.
2. Android: press **Scan pairing QR** and scan it.
3. The phone connects, pins the certificate, and receives a device secret.
4. Later launches reconnect with that secret; no QR is needed.

The QR contains a one-time token that expires after two minutes and can pair one
phone. The long-lived secret is issued only after a successful TLS connection
and is stored in the Android Keystore (AES-GCM) and in a 0600 file on the Mac.
The app enforces one active phone: a second phone gets a clear "already in use"
error, while the same phone can replace its own old session.

The QR payload is:

```
phonedisplay://pair?v=1&host=<lan-ip>&port=<port>&fp=<sha256>&token=<one-time>&id=<mac-uuid>&name=<mac-name>
```

## USB fallback

Wi-Fi is the normal path. For USB, forward the Mac's listener port to the phone:

```sh
adb reverse tcp:8420 tcp:8420
```

Scan the Mac QR as usual. The Android client tries the QR's LAN address first,
then `127.0.0.1:<port>`; both paths use the same pinned certificate. If the Mac
fell back to another port (8421–8439), forward that port instead.

## Display profiles

- **Universal — 1920×1080 at 60 fps** (default, ~10 Mbps).
- **Galaxy S24 — 3120×1440 at 90 fps** (~20 Mbps).

The profile is chosen on the Mac before starting. The phone follows the Mac's
stream rate on first run; the in-app 60/90 pill overrides it and is remembered.
While streaming, tap the top-left corner (or use the pen) to reveal the pill.

## Security model

- Self-signed P-256 TLS identity generated on the Mac and stored 0600.
- The QR carries the certificate SHA-256 fingerprint; Android refuses any other
  certificate. No plaintext token or video is sent.
- Pairing token: 32 random bytes, one use, two-minute expiry.
- Device secret: 32 random bytes, per phone, revocable by re-pairing.
- One active phone at a time.
- Heartbeat every 5 seconds; a silent client is dropped after 15 seconds.
- The virtual display and helper stop after 10 seconds without an active phone.
- Mac sleep, display sleep, and screen lock pause the stream and release the
  virtual display; the phone reconnects after wake/unlock.
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
./tools/package_release.sh
```

Produces:

```
dist/PhoneDisplay-0.1.0-macOS.dmg
dist/PhoneDisplay-0.1.0-android.apk
dist/SHA256SUMS
```

Upload those three files to a GitHub Release. The DMG is ad-hoc signed; the APK
is debug-signed. See `RELEASE.md` for the download/install text.

## Current limits

- The secure Android APK has not yet been installed on a physical phone in this
  workspace (no `adb` device was available). The Mac secure host, QR pairing,
  stored-secret reconnect, one-phone busy rejection, 1080p60, and S24 1440p90
  paths are verified with the TLS test client and synthetic/real capture.
- No Bonjour discovery yet; pairing is QR-only in v1.
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
