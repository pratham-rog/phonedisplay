# PhoneDisplay for macOS

Native SwiftUI shell around the existing `vdhelper`. Built with Swift Package
Manager and Command Line Tools only; no Xcode project.

## Build and run

```sh
./build.sh
open PhoneDisplay.app
```

`build.sh` runs the core checks, builds the app and helper, bundles them, and
ad-hoc signs the app. A downloaded copy needs the usual **Open Anyway** approval.

## Current slice

- Permission checklist for Screen Recording and Accessibility.
- Secure TLS listener with a pinned P-256 self-signed identity.
- Two-minute, one-use QR pairing; per-device 32-byte secrets in 0600
  `devices.json`; one active phone.
- Starts `vdhelper` on the first authenticated phone and tears it down after
  10 seconds without one.
- 1920×1080 at 60 fps (universal) or 3120×1440 at 90 fps (Galaxy S24 profile).
- Sleep, display-sleep, and screen-lock pause.
- Binary H.264/cursor/input protocol after the JSON `pair`/`hello` handshake.
- The old plain-TCP `SocketServer`/`StreamHub` files were removed.

## Developer flags

```sh
# Start the server as soon as the window appears.
open PhoneDisplay.app --args --autostart

# Synthetic video, no Screen Recording permission needed.
PHONEDISPLAY_SYNTHETIC=1 ./PhoneDisplay.app/Contents/MacOS/PhoneDisplay --autostart

# Write a 0600 dev-pairing.json for tools/testclient_tls.py.
PHONEDISPLAY_DEV=1 PHONEDISPLAY_SYNTHETIC=1 \
  ./PhoneDisplay.app/Contents/MacOS/PhoneDisplay --autostart
```

`PHONEDISPLAY_HELPER` overrides the bundled helper path for development.

## Files

- `PairingService.swift` — TLS identity, pairing window, known devices.
- `TLSIdentity.swift` — P-256 identity generation/import and fingerprint.
- `HostServer.swift` — TLS listener, helper lifecycle, frame cache, one-phone
  policy, pause/resume.
- `ClientSession.swift` — JSON handshake, framing, heartbeat, input/control.
- `AppModel.swift` / `ContentView.swift` — app state, permissions, QR UI,
  profile picker.
- `Sources/PhoneDisplayCore` — shared payload, framing, token, and crypto
  helpers with an assert-based check executable.

## Tests

```sh
swift run -c release PhoneDisplayCoreChecks
```

The TLS path is exercised end-to-end with:

```sh
python3 ../../tools/testclient_tls.py 8
```
