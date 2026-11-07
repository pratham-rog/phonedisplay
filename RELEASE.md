# PhoneDisplay 0.1.0 — release notes

Free local second-display app for Android + macOS. No accounts, cloud, App
Store, or Play Store.

## Downloads

- `PhoneDisplay-0.1.0-macOS.dmg`
- `PhoneDisplay-0.1.0-android.apk`
- `SHA256SUMS`

Verify before installing:

```sh
shasum -a 256 -c SHA256SUMS
```

## macOS install

1. Open the DMG and drag **PhoneDisplay** to Applications.
2. The app is ad-hoc signed, not notarized. On first open use
   **System Settings → Privacy & Security → Open Anyway**.
3. Start the app and grant **Screen Recording** and **Accessibility**. Grant
   **Local Network** if macOS asks.
4. Press **Start PhoneDisplay**. A pairing QR appears.

Requires macOS 14 or newer. Apple Silicon is the primary target; Intel is best
effort.

## Android install

1. Copy the APK to the phone and open it. Allow "install unknown apps" for the
   file manager or browser if prompted.
2. The APK is signed with the local debug key and is not from Play Store.
3. Requires Android 8.0 (API 24) or newer.

## Pair

1. Keep the Mac and phone on the same Wi-Fi network.
2. On Android, press **Scan pairing QR** and scan the Mac QR.
3. The phone pins the Mac certificate and stores a per-device secret.
4. Later launches reconnect automatically.

The QR is one-time and expires after two minutes. A second phone gets an
"already in use" message while one phone is active.

### USB (advanced)

```sh
adb reverse tcp:8420 tcp:8420
```

Scan the QR. The Android app tries the LAN address first, then USB loopback. If
the Mac chose a fallback port, forward that port instead.

## Troubleshooting

- **No QR / can't connect:** make sure the phone and Mac are on the same
  network, then press **Show a new pairing QR** on the Mac.
- **macOS says the app is damaged or blocked:** use Open Anyway as above. Do not
  disable Gatekeeper globally.
- **Screen Recording:** after rebuilding from source, macOS may ask again. Grant
  it to PhoneDisplay (and allow the helper if macOS names it).
- **No input:** grant Accessibility to PhoneDisplay. Pointer movement works
  without it; clicks and S-Pen do not.
- **Black screen on a fullscreen Space:** known macOS 27 bug. Move a normal
  window to the phone display, then fullscreen it there.
- **USB:** verify `adb reverse --list` shows `tcp:8420 tcp:8420`, and the phone
  is on the same port as the Mac QR.

## Security

- TLS 1.2+ with certificate pinning.
- One-time 32-byte pairing token, two-minute expiry.
- Per-phone 32-byte secret, stored in Android Keystore and a 0600 Mac file.
- One active phone, 15-second heartbeat timeout, 10-second idle teardown.
- Streams pause on Mac sleep/lock.
- Local network only. No telemetry.

## Build from source

```sh
./tools/package_release.sh
```

Requires macOS Command Line Tools, Java 17, and the Android SDK platform 34.
