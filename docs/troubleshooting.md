# Troubleshooting

## macOS says the app is damaged or cannot be opened

SpareScreen is ad-hoc signed and not notarized. Open **System Settings →
Privacy & Security**, find the blocked-app notice, and choose **Open Anyway**.
Do not disable Gatekeeper globally.

If the app was downloaded as a ZIP or DMG, make sure it was fully extracted
before opening.

## The Mac cannot find the phone

1. Unlock the phone and connect it with a **data** cable.
2. Run:

   ```sh
   adb devices
   ```

   The phone should show as `device`, not `unauthorized` or `offline`.
3. If it is `unauthorized`, accept the USB debugging prompt on the phone, then
   press **Send pairing again** in SpareScreen.
4. If no device appears, enable **Developer options → USB debugging**, try
   another cable or port, and run `adb kill-server && adb start-server`.

## The phone shows “Waiting for the Mac”

- Keep the USB cable connected.
- On the Mac, confirm the phone is selected and press **Send pairing again**.
- Check the reverse mapping:

  ```sh
  adb reverse --list
  ```

  It should contain `tcp:8420 tcp:8420` or a fallback port in `8421–8439`.
- The Mac refreshes the mapping every 5 seconds. If it keeps disappearing, the
  USB connection is unstable.

## Connect does nothing

1. On the Mac, confirm SpareScreen is running and the phone is authorized.
2. On the phone, tap **Connect**.
3. If the phone previously paired with a different Mac, use **Forget this Mac**
   and pair again over USB.
4. Restart both apps if the phone was force-stopped or the Mac was asleep.

## Screen Recording is granted, but the phone stays black

- Grant **Screen Recording** to SpareScreen itself, then restart the app.
- If macOS lists `vdhelper` separately, allow it too; the helper is signed with
  the app's identifier.
- On a static Mac screen, the host replays the last keyframe. If the screen is
  still black, move a window onto the virtual display to force a new frame.
- The macOS 27 fullscreen-Space bug can produce a black frame. Move a normal
  window to the phone display and fullscreen it there.

## Clicks or S-Pen do not work

- Grant **Accessibility** to SpareScreen and restart it.
- Pointer movement works without Accessibility; clicks, scrolling, and S-Pen do
  not.
- Physical S-Pen hover, tap, right-click, and 3× cursor behavior still need a
  hands-on hardware check in this release.

## Android will not install the APK

- Enable **Install unknown apps** for the file manager or browser you use.
- If an earlier debug-signed build is installed, uninstall it first:

  ```sh
  adb uninstall dev.phonedisplay.app
  ```

  Android will not update across a signing-key change. Release builds from
  v0.1.0 onward can update in place.

## The Mac app was replaced and permissions were lost

Re-grant **Screen Recording** and **Accessibility** after rebuilding from
source. The stable signing identity is used to keep permissions across builds;
if it is unavailable, the build falls back to an ad-hoc signature and macOS may
ask again.

## Logs

- macOS app log: `~/Library/Logs/SpareScreen.log`
- Android logcat:

  ```sh
  adb logcat | grep -E 'SpareScreen|AndroidRuntime'
  ```

Never share `host-macos/stream.log`, pairing payloads, device secrets, or
`android/keystore.properties`. Redact tokens and host IDs before posting logs.

## Wi-Fi

Wi-Fi is not supported in this release. USB is the only transport.

## Still stuck?

Open a [bug report](https://github.com/pratham-rog/sparescreen/issues/new/choose)
with the macOS version, Android version and phone model, display profile, exact
steps, and redacted logs. Security issues should follow
[SECURITY.md](../SECURITY.md).
