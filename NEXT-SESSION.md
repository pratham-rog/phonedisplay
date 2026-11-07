# Next session — resume notes

**Status: secure slice built; Mac host and synthetic/real capture verified;
Android APK builds and unit tests pass. Physical phone install and Wi-Fi testing
are blocked because no adb device is attached.**

## Current working tree

- Mac: SwiftUI app, TLS `NWListener`, pinned P-256 identity, QR pairing,
  per-device secrets, one active phone, cached reconnect, heartbeat, 10 s idle
  teardown, sleep/lock pause, universal and S24 display profiles.
- Android: QR scanner, pinned TLS, Keystore-encrypted device secret, saved
  reconnect, Wi-Fi-first with USB loopback fallback, H.264 decode, cursor,
  S-Pen/input, 60/90 selector, queue priority for button events.
- Tests: `PhoneDisplayCoreChecks` 22 checks; `InputPacketQueueTest` 3 checks;
  Python TLS pairing/reconnect; one-phone busy rejection; synthetic 1080p60 and
  1440p90.
- Packaging: `tools/package_release.sh` → DMG, APK, SHA256SUMS.

## Open work

1. Install the APK on the phone when adb is available:
   `adb install -r android/app/build/outputs/apk/debug/app-debug.apk`
2. Scan the Mac QR over Wi-Fi; verify video, cursor, input, S-Pen, reconnect,
   idle teardown, and USB (`adb reverse tcp:8420 tcp:8420`).
3. Re-grant Screen Recording and Accessibility to the final app build. Ad-hoc
   rebuilds reset TCC.
4. Test pairing expiry (2 min), certificate mismatch, and a second phone busy.
5. Run a final real-capture test with the app-level TCC grant.
6. Remaining deferred: Bonjour discovery, Windows host, stable signing keys,
   app icon, physical S-Pen 25 s idle-off test.
7. Known macOS 27 fullscreen-Space bug is an OS issue; use the normal-window
   workaround.

## Gotchas

- `host-macos/stream.log` contains a legacy token; never share it.
- The old `pdctl.py` / `tools/testclient.py` are plain-TCP legacy and do not
  work with the secure app. Use `tools/testclient_tls.py`.
- Mac IP changes; the QR carries the current LAN address at start time.
- TLS listener tries ports 8420–8439; forward the QR's port for USB.
- `PHONEDISPLAY_DEV=1` writes `dev-pairing.json` (0600); delete it before a
  fresh pairing test.
- Test devices live in `~/Library/Application Support/PhoneDisplay/devices.json`
  (0600) and `~/.phonedisplay-test-device*.json` (0600). Remove test entries
  before a clean handoff.
