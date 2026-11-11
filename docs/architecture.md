# Architecture

SpareScreen has two native apps and one shared protocol.

```text
┌────────────────────┐       USB cable / ADB reverse       ┌─────────────────────┐
│ Android phone      │◄───────────────────────────────────►│ macOS host          │
│ Kotlin client      │                                     │ SwiftUI + vdhelper  │
│                    │       TLS 1.2+, pinned certificate  │                     │
│ H.264 decoder      │◄───────────────────────────────────►│ ScreenCaptureKit    │
│ fullscreen surface │                                     │ VideoToolbox H.264  │
└────────────────────┘                                     └─────────────────────┘
```

## Components

### macOS app (`mac/PhoneDisplay`)

- SwiftUI shell for permissions, profiles, pairing status, and diagnostics.
- `HostServer` owns the TLS listener, one-phone policy, frame cache, and helper
  lifecycle.
- `PairingService` creates the host identity, one-time pairing window, and
  per-device secrets.
- `HelperProcess` starts the bundled `vdhelper`, forwards input, and parses its
  binary stream.
- `PhoneDisplayCore` contains payload, framing, token, and crypto helpers shared
  by the app and its assert-based checks.

### Host helper (`host-macos/vdhelper`)

Objective-C helper built with Command Line Tools only. It creates a virtual
display through CoreGraphics, captures it with ScreenCaptureKit, hardware-encodes
H.264 with VideoToolbox, and emits cursor/input frames. The helper is signed with
the app's identifier so the app's Screen Recording grant covers it.

### Android client (`android`)

Kotlin app using `MediaCodec` for hardware H.264 decode and a fullscreen
`SurfaceView`. `PinnedTls` performs the certificate check. `SecretStore` keeps the
per-device secret in the Android Keystore (AES-GCM). `CursorView` renders the
remote pointer and pen state.

## Pairing

1. The Mac runs `adb reverse tcp:8420 tcp:8420` (or the next free port in
   `8421–8439`) for the authorized device.
2. The Mac creates a one-time token and sends a base64 pairing intent through
   ADB. The payload carries the host, port, certificate SHA-256 fingerprint, host
   ID, and display name.
3. The phone connects to `127.0.0.1:8420`, verifies the pinned certificate, and
   presents the one-time token.
4. The Mac issues a 32-byte per-device secret. The phone stores it in the Android
   Keystore; the Mac stores it in a `0600` device file.
5. Later launches authenticate with the device secret. Re-pairing rotates it.

The token expires after two minutes and can pair one phone. The long-lived
device secret is never printed and is never sent over an unprotected link.

## Protocol

After the TLS handshake:

- A JSON `pair`/`hello` exchange authenticates the device and negotiates the
  stream.
- Binary frames carry H.264 video, cursor state, and input events.
- Heartbeats run every 5 seconds; a silent client is dropped after 15 seconds.
- The Mac keeps the last encoded keyframe and replays it when a reconnecting
  phone requests a keyframe on a static screen.
- The helper and virtual display stop after 10 seconds without an active phone.

## Display profiles

| Profile | Resolution | Refresh | Approx. bitrate | Notes |
| --- | --- | --- | --- | --- |
| Universal | 1920×1080 | 60 fps | ~10 Mbps | Default; fill mode center-crops top/bottom |
| Galaxy S24 | 3120×1440 | 90 fps | ~20 Mbps | Exact fill for the SM-S928B panel |

## Security boundaries

- The listener is reachable only through the USB reverse mapping.
- TLS identity is self-signed and pinned by fingerprint; Android rejects any
  other certificate.
- One active phone at a time.
- No telemetry, accounts, cloud services, or plaintext stream transport.
- Secrets are excluded from the repository and from normal logs. See
  [SECURITY.md](../SECURITY.md).

## Build and release

- macOS: `mac/PhoneDisplay/build.sh` builds the app and helper and signs the
  bundle. `tools/package_release.sh` creates the DMG.
- Android: Gradle `:app:assembleRelease` with the local release key.
- Release artifacts and checksums are produced under `dist/`.
