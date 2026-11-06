# PhoneDisplay for macOS

Native SwiftUI shell around the existing `vdhelper`. Built with Swift Package
Manager and Command Line Tools only; no Xcode project.

## Build and run

```sh
./build.sh
open PhoneDisplay.app
```

`build.sh` runs the core checks, builds the app and helper, bundles them, and
ad-hoc signs the app. The app is unsigned by Apple, so a downloaded copy needs
the usual **Open Anyway** approval.

## Current slice

- Permission checklist for Screen Recording and Accessibility.
- Starts `vdhelper` on the first authenticated client and tears it down after
  10 seconds without one.
- 1920×1080 at 60 fps, 10 Mbps.
- Existing `PD01 <token>` protocol on TCP port 8420, so the current Android app
  and `tools/testclient.py` work unchanged.
- QR payload for the new Android app: `phonedisplay://connect?v=1&...`.
- Plain TCP only. TLS and per-device pairing are the next slice.

## Developer flags

```sh
# Start the server as soon as the window appears.
open PhoneDisplay.app --args --autostart

# Synthetic video, no Screen Recording permission needed.
open PhoneDisplay.app --args --autostart --synthetic

# Use a helper outside the bundle.
PHONEDISPLAY_HELPER=/path/to/vdhelper open PhoneDisplay.app
```

The helper is at `PhoneDisplay.app/Contents/Helpers/vdhelper`.

## Checks

```sh
swift run PhoneDisplayCoreChecks
python3 ../../tools/testclient.py 127.0.0.1 8420 5
```

The token is read from `~/.phonedisplay-token`; never print or commit it.

## Permissions

The app is the responsible process for both permissions. Grant Screen Recording
to **PhoneDisplay**, not to `vdhelper`. Screen Recording may require a restart;
use **Restart app** in the window. Accessibility is needed for clicks and S-Pen
input; pointer movement works without it.
