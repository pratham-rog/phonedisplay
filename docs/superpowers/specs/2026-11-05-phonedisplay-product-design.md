# PhoneDisplay — product design

Status: draft for approval  
Date: 2026-11-05  
Working name: PhoneDisplay

## Intent

Turn the working PhoneDisplay prototype into a free product that a normal person
can install on their own Mac and Android phone:

1. Download a DMG from GitHub Releases.
2. Drag the app to Applications.
3. Get past the one-time macOS Gatekeeper warning.
4. Grant the two permissions the app explains.
5. Install the APK on the phone.
6. Scan the QR code shown by the Mac.
7. Use the phone as a second display.

No Terminal, no IP addresses, no copying a token. The product is free of cost:
GitHub Releases only, no App Store, no Play Store, no Apple Developer Program,
no paid services, no telemetry.

## Who it is for

- A person with an Android phone and a Mac who wants a second screen without
  buying a monitor.
- The first release targets technical friends and early adopters who can follow
  a short illustrated install guide. The product experience is designed for a
  nontechnical person, but the free macOS distribution cannot remove the one
  Gatekeeper approval step.
- Samsung S-Pen users get pen control. Other Android phones get the display;
  touch input is a later milestone, not a v1 promise.

## Success

A fresh user can go from a GitHub release to a working second display in under
five minutes, with one QR scan and two required macOS permission grants (plus a
conditional Local Network/firewall prompt). The stream reconnects after a
cable/Wi-Fi drop, the display disappears when the phone leaves, and the Mac
never shows a phantom display.

On the reference S24 Ultra: 3120×1440, 90 fps, 3× cursor, S-Pen hover/click/drag,
and the existing idle behavior. On a typical 1080p Android phone: 1920×1080 at
60 fps, display-only, letterboxed correctly.

## Goals

- A native macOS menu-bar app with a real window, onboarding, permission
  checklist, pairing QR, connected-device status, settings, and logs.
- Keep the proven ObjC `vdhelper` as the virtual-display/capture/encode engine;
  port `pdctl.py` orchestration to Swift.
- A native Android app with discovery, QR pairing, saved Macs, reconnect,
  capability negotiation, fullscreen H.264 decode, and the existing S-Pen path.
- TLS with a pinned self-signed Mac identity. No plaintext token on the wire.
- Dynamic mode selection: match the phone's landscape resolution where macOS
  accepts it; otherwise fall back to 1920×1080. Cap at 3120×1440 and 90 fps.
- Permission onboarding that opens the exact macOS Settings panes and reports
  live status.
- A repeatable free release pipeline: DMG, APK, SHA-256 sums, install guide,
  GitHub Actions, no paid signing.
- Preserve the verified H.264 path, cursor overlay, idle display teardown, and
  stable display identity.

## Non-goals

- iPhone/iOS, Windows, Linux, Android TV, or Chromebooks.
- Audio, HDR, HEVC, 120 fps, or 4:4:4.
- Internet/remote access, relay servers, accounts, cloud pairing, or telemetry.
- App Store or Play Store distribution.
- Apple Developer Program membership, notarization, or a paid signing service.
- Multiple simultaneous phones in v1. One active phone per Mac.
- Keyboard forwarding, touchpad mode, pressure/tilt, or multi-touch gestures in
  v1. S-Pen input stays; finger input remains ignored.
- Auto-update. The app shows its version and links to GitHub Releases.
- A guarantee that every Mac or Android device works. There is a supported
  matrix and a clear unsupported message.

## Constraints

- The virtual display uses the private `CGVirtualDisplay` API. This rules out
  the Mac App Store. It may change or disappear in a future macOS.
- Free distribution means ad-hoc code signing and a manual Gatekeeper approval.
  macOS may require permissions to be granted again after an app update because
  an ad-hoc identity is not stable. A future paid Developer ID removes this.
- Target macOS 14 Sonoma or newer. Apple Silicon is the primary target; Intel is
  best-effort until tested on real Intel hardware. The app checks for
  `CGVirtualDisplay` at runtime and shows an unsupported message if absent.
- Android `minSdk 24` (Android 7). H.264 hardware decode is required. Devices
  without a usable H.264 decoder show an unsupported message.
- H.264 only, SDR only, 90 fps maximum. The existing encoder is the ceiling.
- GitHub Releases only. The repository must be public for free GitHub Actions
  macOS runners; private-repo minutes are the owner's cost.
- No secret may appear in logs, screenshots, README examples, or error text.

## Approaches considered

### 1. Native product (chosen)

SwiftUI macOS app plus the existing ObjC helper; port the Python hub to Swift.
Android app gets a real connection/pairing flow. This is the only approach that
matches “a normal person installs it and it works,” and it removes the Python
runtime from the user’s Mac. It is the largest rewrite, but the hard video path
stays in the helper and is re-verified.

### 2. Wrapper MVP

A SwiftUI shell that launches a PyInstaller-bundled Python host plus the helper.
Fastest to a DMG, but ships two runtimes, makes permission attribution and
signing harder, and leaves a Python process in a product that is supposed to
feel native. Rejected for the product; may be used as a temporary test harness.

### 3. Android polish only

Keep the CLI host and improve the phone app. Cheapest, but a normal person still
needs Terminal and `adb`; it fails the product goal. Rejected.

## Product experience

### Mac install and first run

1. Download `PhoneDisplay-<version>.dmg` from GitHub Releases and verify the
   published SHA-256 if desired.
2. Open the DMG and drag `PhoneDisplay.app` to Applications.
3. First launch: macOS blocks the ad-hoc-signed app. The release guide shows the
   exact **System Settings → Privacy & Security → Open Anyway** step with
   screenshots for the supported macOS versions.
4. The app opens a setup window with a permission checklist:
   - **Screen Recording** — needed to capture the virtual display.
   - **Accessibility / Device Control and Data Access** — needed to inject
     clicks. Pointer movement works without it; clicks do not.
   Each row shows status, why it is needed, and a button that opens the exact
   Settings pane. The app re-checks when it becomes active.
   If macOS 15+ shows a **Local Network** prompt, or the firewall asks whether
   the app may accept incoming connections, the app shows a third card with the
   exact pane or dialog instruction. These are conditional, not always present.
   Screen Recording may require quitting and reopening the app; the checklist
   offers a **Restart PhoneDisplay** button and re-checks after relaunch.
5. The app starts the local server and shows **Pair a phone** with a QR code.
6. Closing the window keeps the app in the menu bar. Quit from the menu bar.

The app does not require Terminal, Python, Homebrew, or `adb` for the normal
Wi-Fi path. An advanced USB mode may use `adb` if it is already installed; it is
not part of first-run onboarding.

### Android install and first run

1. Download `PhoneDisplay-<version>.apk` from the same GitHub release.
2. Allow install from this source when Android asks.
3. Open the app. Grant camera permission only when scanning the QR code.
4. The app lists discovered Macs on the same network. If discovery is blocked,
   the user taps **Scan QR** or opens **Having trouble? → Enter details**.
5. Scan the Mac’s QR. The app stores the Mac identity and pairing secret.
6. Connect. The phone goes fullscreen landscape and shows the Mac display.
7. Returning to the app auto-reconnects to the last Mac. **Choose another Mac**
   returns to the device list.

### Pairing

Pairing is a one-time exchange that creates a per-device long-lived secret. The
QR token and the 8-character code are bootstrap secrets, not the long-lived
device secret.

1. The Mac app generates a P-256 self-signed TLS identity on first run and stores
   the private key in a 0600 file under Application Support. It generates a
   stable host UUID at the same time.
2. **Pair a phone** opens a two-minute pairing window. The window shows a QR
   payload:
   `phonedisplay://pair?v=1&host=<lan-ip>&port=<port>&fp=<sha256>&token=<pairing-token>&id=<host-uuid>&name=<mac-name>`.
   It also shows an 8-character code for manual entry.
3. The Android app verifies the payload, connects with TLS, pins the certificate
   fingerprint, and sends a `pair` message with the QR token or the 8-character
   code plus its device name/model.
4. The host validates the bootstrap secret while the window is open, creates a
   32-byte per-device secret, stores `host UUID + device ID + secret + name`, and
   replies with `paired` containing the device ID and secret. The pairing window
   closes after one success.
5. The phone stores host UUID, address, port, certificate fingerprint, device ID,
   and device secret in Keystore-encrypted storage. It then sends `hello` with the
   device ID and secret. The host accepts and starts the stream.
6. Reconnect uses only `hello`; the pairing window is not needed. The phone
   matches a discovered Mac by host UUID and updates the saved address if DHCP
   changed it. If discovery is blocked, it tries the saved address and shows a
   manual retry.
7. A changed certificate fingerprint is a hard error: “This Mac’s identity
   changed. Pair again.” A revoked or unknown device gets “Pair this phone
   again.”
8. Manual fallback shows the certificate fingerprint on both screens for visual
   comparison before the phone sends the 8-character code. No silent
   trust-on-first-use. Failed manual attempts are limited to five per minute.
9. If the QR/code expires before the phone connects, the phone says “Pairing
   expired — show a new QR on the Mac.” The Mac can reopen the window.
10. The Mac app can forget a device; the phone must pair again. The host keeps at
    most 32 known devices.

### Network address and discovery

- The host UUID is stable and independent of the IP address.
- Bonjour advertises `_phonedisplay._tcp` with TXT `v=1`, `id=<host-uuid>`,
  `name=<mac-name>`. No secret is advertised.
- The phone matches discovered Macs by host UUID, not by IP. If the saved address
  fails and the Mac is discovered at a new address, the phone updates the saved
  address and reconnects.
- The Mac app chooses the QR address from the active interface with the default
  route. If more than one interface is active, it shows a small “Network: …”
  picker with all non-loopback IPv4 addresses. The phone-hotspot case is just a
  Wi-Fi interface; QR is the reliable path when mDNS is blocked.
- Manual fallback uses the same host UUID and fingerprint check; it does not
  create a second identity.
- A phone on a different network cannot connect; the app says “Same Wi-Fi
  network required” and offers QR/manual retry. No relay.

### Streaming and errors

- While streaming: fullscreen, screen kept awake, small status pill with fps and
  connection state, and a tap target to return to the connect screen.
- The existing S-Pen behavior is preserved: hover moves, tap clicks, side-button
  tap right-clicks, drag holds until lift, 20 s idle-off, palm ignored.
- Reconnect: 3 s backoff, then 5 s, then 10 s, capped at 10 s; manual retry.
- Errors are plain language: Mac not found, wrong network, permission missing,
  Mac busy, version mismatch, decoder unsupported, connection lost.
- No phantom display: create the virtual display on the first authenticated
  client; tear it down after 10 s with no clients.
- One active phone. A different phone is rejected with “This Mac is already in
  use.” A connection from the *same* device secret replaces the old session,
  releases any held button, and starts a fresh session ID; this makes the 3 s
  reconnect after a drop work without waiting for the 15 s heartbeat timeout.
- Mac sleep/lock: stop advertising, tear down the helper/display, and close
  clients with “Mac asleep or locked.” On wake/unlock, start advertising again;
  the phone auto-reconnects and the display is recreated on demand. The app does
  not capture the lock screen or stream while the session is inactive.
- Mac shutdown/quit: clients see “Mac unavailable”; no display remains.

## Architecture

### macOS app

A SwiftUI app built with Swift Package Manager plus a small `build.sh` that
produces `PhoneDisplay.app`; no Xcode project is required. The app is a regular
app with a menu-bar extra.

Modules:

- `PhoneDisplayApp` — app lifecycle, windows, menu bar.
- `AppModel` — observable state: permissions, server, pairing, connected phone.
- `PermissionService` — Screen Recording and Accessibility preflight/request,
  Settings deep links, re-check on activation.
- `PairingService` — TLS identity and known-device store in 0600 files under
  Application Support, QR payload, pairing window, revoke.
- `HostServer` — `NWListener` on TCP + TLS, Bonjour advertisement, connection
  limits, watchdog.
- `StreamSession` — authenticated client state, handshake, mode selection,
  frame broadcast, input forwarding, held-button release.
- `HelperProcess` — spawns the bundled `vdhelper`, parses its stdout
  (`u32 length | u8 flags`), forwards input to stdin, restarts on crash, kills on
  quit, watches first-frame liveness.
- `DisplayMode` — chooses width/height/refresh/fps/bitrate, polls the virtual
  display from outside, restores the pinned mode after a macOS mode change.
- `InputRouter` — per-client input state and button release on disconnect.
- `Diagnostics` — redacted log file, copy-diagnostics, version info.
- `Settings` — fps ceiling, idle grace, launch at login (later), advanced USB.

The helper stays ObjC (`vdhelper.m`) and is bundled at
`PhoneDisplay.app/Contents/Helpers/vdhelper`. The app owns TCC prompts; the
helper is launched by the app so the app is the responsible process. The build
script signs the helper first, then the app, ad-hoc.

### Android app

Kotlin, Jetpack Compose for the shell, `SurfaceView` for video. `minSdk 24`,
`targetSdk 35`, no Google Play Services.

Modules:

- `MainActivity` — Compose navigation: welcome, devices, scan, connecting,
  streaming, error, settings.
- `DiscoveryClient` — `NsdManager` for `_phonedisplay._tcp`; explicit
  refresh; fallback to QR/manual.
- `PairingStore` — Keystore AES/GCM-encrypted JSON in app storage; no plaintext
  secrets in SharedPreferences.
- `TlsClient` — `SSLSocket` with a pinning `TrustManager`; hostname verification
  disabled only because the certificate is pinned by fingerprint.
- `Protocol` — versioned JSON handshake, binary frame parser, cursor parser,
  input writer, heartbeat.
- `VideoDecoder` — `MediaCodec` H.264 decoder to the Surface; capability query;
  keyframe wait; idle flush; reconfigure on failure.
- `CursorView` — existing 3× cursor overlay.
- `PenInput` — existing S-Pen path, preserved.
- `ConnectionViewModel` — state machine and user-facing errors.
- `QrScanner` — ZXing embedded scanner or CameraX + ZXing core; camera
  permission requested only when opened.
- `Settings` — 60/90 fps choice, show stats, forget Mac, version.

The phone app does not request location. If a device’s NSD is unreliable, QR and
manual entry are the supported fallbacks.

### Protocol

TLS 1.2+ over TCP, default port 8420 (fallback to the next free port; Bonjour and
QR carry the actual port).

1. Client connects and verifies the pinned certificate.
2. **First pairing only:** client sends one JSON line:
   `{"type":"pair","v":1,"token":"<qr-token-or-8-char-code>","device":{"name":...,"model":...}}`
   Host replies `{"type":"paired","v":1,"deviceId":"...","secret":"<base64url>"}`.
3. Client sends one JSON line:
   `{"type":"hello","v":1,"deviceId":"...","auth":"<secret>","device":{"name":...,"model":...},"display":{"width":...,"height":...,"refresh":...},"decode":{"codecs":["h264"],"maxWidth":...,"maxHeight":...,"maxFps":...}}`
4. Host validates the secret in constant time and replies with one JSON line:
   `{"type":"stream","v":1,"width":...,"height":...,"fps":...,"bitrate":...,"codec":"h264","fallback":false}`
   or `{"type":"error","code":"busy|permission|version|revoked|unsupported","message":"..."}`
   followed by a close.
5. Binary messages follow, reusing the helper framing:
   `u32_be length | u8 flags | payload`.
   Flags: `0x01` keyframe video, `0x02` cursor, `0x04` control.
6. Control payloads are JSON:
   - phone → host: `{"type":"fps","value":90}` (live; no reconnect),
     `{"type":"keyframe"}`, `{"type":"stats","fps":...,"dropped":...}`.
   - host → phone: `{"type":"fps","value":90}`, `{"type":"error",...}`,
     `{"type":"notice","message":"Using a safe resolution"}`.
7. Input packets from the phone use the existing 10-byte helper format.
8. Client sends a heartbeat every 5 s; host drops a client after 15 s of silence
   and releases any held button.
9. A version mismatch closes with a human-readable “update the other side”
   message.

The helper’s stdout protocol is unchanged; the host app repackages helper frames
into authenticated client messages. The helper’s stdin commands `F <fps>` and
`K` are used for live fps changes and keyframe requests.

### Mode selection

The phone reports its landscape width/height and refresh rate.

- Preferred mode: the phone’s landscape resolution, if width ≤ 3120, height ≤
  1440, and the helper can create it.
- Fallback: 1920×1080, then 1280×720.
- FPS: `min(phone refresh, 90, host setting)`. Default 60 when the phone does not
  report a reliable value. The reference S24 uses 90.
- Bitrate: approximately 0.09 bits per pixel per frame, clamped to 6–35 Mbps.
  Examples: 3120×1440@90 → 35 Mbps; 1920×1080@60 → 11 Mbps.
- Display name: `PhoneDisplay`; stable serial derived from name + pixel size so
  macOS remembers the arrangement per mode.
- The host app polls the display from outside and restores the pinned mode if
  macOS changes it, using the existing `pdctl` logic ported to Swift.
- If the helper cannot create the requested mode, it falls back and the phone
  scales/letterboxes; the app shows “Using a safe resolution” once.

### Security

- TLS with a self-signed P-256 certificate; the certificate fingerprint is in
  the QR and pinned by the phone.
- Pairing bootstrap: a 32-byte QR token or an 8-character manual code, valid only
  while the two-minute window is open and for one success. It is never the
  long-lived secret.
- Per-device secret: 32 random bytes, base64url, issued once by the host after a
  successful pairing. The phone stores it in Keystore-encrypted storage. The Mac
  stores the device ID, name, and secret in a 0600 file under Application
  Support. Never logged.
- Why a file, not the Mac Keychain: ad-hoc code signing changes the app’s
  designated requirement on every build, which can make Keychain items
  inaccessible or prompt after an update. A 0600 file owned by the user survives
  updates. Revisit Keychain when a stable Developer ID exists.
- If the identity file is missing or corrupt, generate a new identity and require
  re-pairing; show a clear message rather than silently trusting a new key.
- Pairing window: two minutes, one new device, then closes.
- Constant-time secret comparison; five failed handshakes per minute per IP, then
  a 60 s pause; close on malformed lengths or oversized frames.
- Same-device reconnect replaces the old session and releases held buttons; a
  different device gets `busy`.
- Input injection is enabled only after authentication.
- The server listens only while the Mac app is running and available. It
  advertises only on the local network. No cloud, no relay, no telemetry.
- Logs redact secrets, fingerprints may be truncated, and “Copy diagnostics”
  excludes secrets.
- Free-signing limitation: ad-hoc signing does not provide a stable trusted
  identity; Gatekeeper approval and permission grants may need repeating after
  updates. This is documented, not hidden.

### Packaging and distribution

- GitHub Releases contains:
  - `PhoneDisplay-<version>.dmg`
  - `PhoneDisplay-<version>.apk`
  - `SHA256SUMS.txt`
  - release notes with install/permission/troubleshooting steps
- DMG: drag-to-Applications layout, app icon, short “first launch” note.
- Mac app: ad-hoc signed, no notarization. The guide covers the one-time
  **Open Anyway** step for macOS 14/15/26.
- APK: release-signed with a key stored in GitHub Actions secrets; the owner
  keeps an offline backup. If the key is lost, users must uninstall/reinstall.
- GitHub Actions:
  - macOS runner builds the Swift app and helper, bundles, signs ad-hoc, creates
    the DMG, writes checksums.
  - Ubuntu runner builds the release APK, writes checksums.
  - Tag push creates the GitHub Release and uploads artifacts.
- Versioning: semantic `MAJOR.MINOR.PATCH`; host and phone show the version;
  protocol v1 compatibility is checked at handshake.
- No auto-update in v1. The app links to the release page.

## Testing

- Unit: pairing payload/QR, secret storage, TLS fingerprint validation, protocol
  encode/decode, mode selection, bitrate/fps caps, error mapping.
- Host integration: helper spawn/parse, first frame, static frame, keyframe
  replay, cursor, input round-trip, disconnect releases held button, helper
  crash restart, idle teardown, mode restore after a macOS mode change,
  same-device reconnect takeover, sleep/lock teardown and wake reconnect.
- Security: wrong secret, wrong fingerprint, replayed pairing token, expired
  token, malformed frame lengths, oversized frames, slow client, pairing window
  expiry, rate limit, revoked device.
- Android: unit tests for protocol/pairing store; emulator UI tests for API 24,
  28, 34, 35; real S24 for 3120×1440@90, S-Pen, reconnect, idle; at least one
  other physical Android phone for 1080p/60 if available.
- Install: clean macOS user account or VM for Gatekeeper and TCC; APK sideload
  on a clean phone profile.
- Performance: 1080p60 and 3120×1440@90; frame drops, CPU, memory, reconnect
  time, first-frame time.
- Regression: keep the existing host selftest and test client working against
  the new protocol where practical.

## Milestones

1. **Vertical slice.** Mac app shell, permissions checklist, helper integration,
   TLS server, QR pairing; Android shell, QR scan, TLS, 1920×1080@60 video on
   the S24. One phone, no discovery yet.
2. **Product quality.** Discovery, saved Macs, reconnect, 3120×1440@90,
   dynamic mode/fallback, cursor, S-Pen, error states, idle teardown, settings.
3. **Free release.** DMG, APK signing, GitHub Actions, checksums, install guide,
   README, release notes, clean-account install test.
4. **Compatibility and hardening.** Android 7–16 test pass, at least one
   non-Samsung phone, Intel Mac if available, security audit, performance,
   accessibility pass, final bug fixes.

## Open decisions for the builder

- Exact minimum macOS after testing the private API on 14/15/26; target is 14.
- Intel support: best-effort until real hardware is available.
- QR scanner: ZXing embedded vs CameraX + ZXing core. Pick the smaller reliable
  integration.
- Compose vs XML for the Android shell; Compose is the proposal.
- App icon, accent color, and final product name; “PhoneDisplay” is a working
  name.
- Open-source license; MIT is the proposal.
- Whether to expose the advanced USB/`adb` mode in v1 settings or keep it
  developer-only.
- Touchpad mode and keyboard forwarding: later milestones, not v1.

## Risks

- The private `CGVirtualDisplay` API may break or be missing on some macOS
  versions. No App Store, no notarization, no paid fallback in v1.
- Gatekeeper and ad-hoc signing create real friction and permission resets.
- “Any Android phone” is a broad matrix; decoder quirks, NSD differences, and
  OEM skins will produce bugs we cannot test exhaustively.
- Porting `pdctl.py` to Swift can regress the verified video path; the helper
  stays, and integration tests must cover the old behaviors.
- TLS/pairing is security-sensitive; a mistake could expose input injection.
- Phone-hotspot Wi-Fi may block mDNS; QR/manual entry must work.
- High-resolution/high-fps H.264 remains hardware-limited; fallback must be
  automatic.
- GitHub-only distribution means users may run mismatched host/phone versions;
  the protocol check must fail clearly.
- Free GitHub Actions macOS minutes depend on a public repository; a private
  repo adds cost.
