# SpareScreen 0.1.1 — release notes

SpareScreen is the new public name of PhoneDisplay. The app is the same
local-only USB second-display tool, with a cleaner public identity and release
packaging. Internal bundle/application IDs and the release signing key are
unchanged, so v0.1.0 release installs can update in place.

Free local second-display app for Android + macOS. No accounts, cloud, App
Store, or Play Store. This release uses USB.

## Downloads

- `SpareScreen-0.1.1-macOS.dmg`
- `SpareScreen-0.1.1-android.apk`
- `SHA256SUMS`

Verify before installing:

```sh
shasum -a 256 -c SHA256SUMS
```

## What changed

- Public product and GitHub repository renamed to **SpareScreen**.
- macOS app bundle is now `SpareScreen.app`; the internal executable and bundle
  identifier remain `dev.phonedisplay.app` for upgrade compatibility.
- Android app label is now **SpareScreen**; the application ID remains
  `dev.phonedisplay.app`.
- Release artifacts are named `SpareScreen-<version>-*`.
- Added MIT licensing, contribution/security/community documentation, issue and
  pull-request templates, CI, and troubleshooting/architecture docs.
- APK remains release-signed; it is not a Play Store build.

## macOS install

1. Open the DMG and drag **SpareScreen** to Applications.
2. The app is ad-hoc signed, not notarized. On first open use
   **System Settings → Privacy & Security → Open Anyway**.
3. Start the app and grant **Screen Recording** and **Accessibility**. Grant
   **Local Network** only if macOS asks; USB does not use it.
4. Press **Start SpareScreen**.
5. If an older `PhoneDisplay.app` is still in Applications, remove it after
   confirming SpareScreen works.

Requires macOS 14 or newer. Apple Silicon is the primary target; Intel is best
effort.

## Android install

1. Copy the APK to the phone and open it. Allow “install unknown apps” for the
   file manager or browser if prompted.
2. The APK is signed with the local release key and is not from Play Store.
3. Requires Android 8.0 (API 24) or newer.
4. If an earlier debug-signed build is installed, uninstall it first. Android
   will not update across a signing-key change. Release builds from v0.1.0
   onward can update in place.

## Pair over USB

1. Enable **Developer options → USB debugging** on the phone.
2. Connect the phone to the Mac with a USB data cable and authorize the Mac
   when prompted.
3. On the Mac, press **Start SpareScreen**. It finds the authorized ADB device,
   sets up `adb reverse`, and opens the Android app with a one-time pairing
   intent.
4. The phone pins the Mac certificate and stores a per-device secret. Later
   launches reconnect automatically; press **Connect** on the phone if needed.

The pairing token expires after two minutes and pairs one phone. A second phone
gets an “already in use” message while one phone is active.

If the Mac uses a fallback port (8421–8439), the app forwards that port instead
of 8420 automatically.

## Troubleshooting

- **USB not ready / no authorized device:** run `adb devices`; unlock the phone
  and accept the USB debugging prompt, then press **Send pairing again**.
- **Can’t connect:** verify `adb reverse --list` shows
  `tcp:8420 tcp:8420` (or the fallback port), then press **Connect** on the
  phone. The Mac refreshes the mapping every 5 seconds.
- **macOS says the app is damaged or blocked:** use Open Anyway as above. Do not
  disable Gatekeeper globally.
- **Screen Recording:** after rebuilding from source, macOS may ask again. Grant
  it to SpareScreen (and allow the helper if macOS names it).
- **No input:** grant Accessibility to SpareScreen. Pointer movement works
  without it; clicks and S-Pen do not.
- **Black screen on a fullscreen Space:** known macOS 27 bug. Move a normal
  window to the phone display, then fullscreen it there.
- **Black screen after reconnecting on a static Mac:** fixed; the host replays
  the last encoded keyframe.

More: [docs/troubleshooting.md](docs/troubleshooting.md).

## Security

- TLS 1.2+ with certificate pinning.
- One-time 32-byte pairing token delivered over USB/ADB, two-minute expiry.
- Per-phone 32-byte secret, stored in Android Keystore and a 0600 Mac file.
- One active phone, 15-second heartbeat timeout, 10-second idle teardown.
- Streams pause on Mac sleep/lock.
- Local link only. No telemetry.

## Build from source

```sh
VERSION=0.1.1 ./tools/package_release.sh
```

Requires macOS Command Line Tools, Java 17, and the Android SDK platform 34. Set
`JAVA_HOME` to a JDK 17 if Gradle or `apksigner` cannot find Java. Release
builds require the git-ignored `android/keystore.properties` and its keystore;
back both up.

## License

MIT. See [LICENSE](LICENSE).
