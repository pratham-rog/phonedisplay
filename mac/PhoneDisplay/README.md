# SpareScreen for macOS

Native SwiftUI shell around the `vdhelper` virtual-display helper. Built with
Swift Package Manager and Command Line Tools only; no Xcode project.

The public app is **SpareScreen**. The internal executable, bundle identifier
(`dev.phonedisplay.app`), signing identity, and pairing storage keep their old
names so existing installs and permissions survive the rename.

## Build and run

```sh
./build.sh
open SpareScreen.app
```

`build.sh` runs the core checks, builds the app and helper, bundles them, and
signs the app. A downloaded copy needs the usual **Open Anyway** approval.

## Current slice

- Permission checklist for Screen Recording and Accessibility.
- Secure TLS listener with a pinned P-256 self-signed identity.
- Two-minute, one-use USB pairing; per-device 32-byte secrets in a 0600
  `devices.json`; one active phone.
- Starts `vdhelper` on the first authenticated phone and tears it down after
  10 seconds without one.
- 1920×1080 at 60 fps (universal) or 3120×1440 at 90 fps (Galaxy S24 profile).
- Sleep, display-sleep, and screen-lock pause.
- Binary H.264/cursor/input protocol after the JSON `pair`/`hello` handshake.

## Developer flags

```sh
# Start the server as soon as the window appears.
open SpareScreen.app --args --autostart

# Synthetic video, no Screen Recording permission needed.
PHONEDISPLAY_SYNTHETIC=1 ./SpareScreen.app/Contents/MacOS/PhoneDisplay --autostart

# Write a 0600 dev-pairing.json for tools/testclient_tls.py.
PHONEDISPLAY_DEV=1 PHONEDISPLAY_SYNTHETIC=1 \
  ./SpareScreen.app/Contents/MacOS/PhoneDisplay --autostart
```

`PHONEDISPLAY_HELPER` overrides the bundled helper path for development. The
`PHONEDISPLAY_*` environment names are intentionally unchanged for scripts.

## Files

- `PairingService.swift` — TLS identity, pairing window, known devices.
- `TLSIdentity.swift` — P-256 identity generation/import and fingerprint.
- `HostServer.swift` — TLS listener, helper lifecycle, frame cache, one-phone
  policy, pause/resume.
- `ClientSession.swift` — JSON handshake, framing, heartbeat, input/control.
- `AppModel.swift` / `ContentView.swift` — app state, permissions, pairing UI,
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
