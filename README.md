# PhoneDisplay

Use your Android phone as a **true second monitor** for your Mac (Windows later).

```
┌───────────────────────── Mac (host) ─────────────────────────┐
│                                                              │
│  vdhelper (Objective-C, compiled with clang)                 │
│   ├─ 1. create virtual display   ← CGVirtualDisplay API      │
│   ├─ 2. capture it               ← ScreenCaptureKit          │
│   └─ 3. encode H.264 frames      ← VideoToolbox (hardware)   │
│                    │ length-prefixed NAL units               │
│                    ▼                                          │
│  pdctl.py  ── TCP server on your LAN ──► ...                 │
│                                                              │
└──────────────────────────────────────────────────────────────┘
                        │  Wi-Fi / USB tether
                        ▼
┌───────────────────────── Phone ──────────────────────────────┐
│  Android app (Kotlin)                                        │
│   ├─ connect to host, receive H.264                          │
│   ├─ hardware-decode (MediaCodec)                            │
│   └─ render fullscreen, keep screen awake                    │
└──────────────────────────────────────────────────────────────┘
```

## Why this design

- The only hard part on the Mac is **creating a virtual display and encoding video** —
  that lives in a small native helper (`vdhelper`, written for you).
- Everything else is Python (`pdctl.py`) and Kotlin (Android) — easy to iterate on.
- No kernel extensions, no drivers, no Xcode project needed.

## Roadmap

| # | Milestone | Status |
|---|-----------|--------|
| 1 | Virtual monitor appears on the Mac | ✅ verified (macOS 27, M4 — see notes below) |
| 2 | Capture it + H.264 encode + TCP server | ✅ verified end-to-end (needs one-time Screen Recording grant) |
| 3 | Android app: connect, decode, fullscreen render | ✅ verified — Galaxy S24 Ultra over USB, live Mac desktop at 60–110 fps (≈106 fps sustained at 3120×1440) |
| 4 | Polish: USB mode, mDNS auto-discovery, reconnect, resolution/rotation control | 🚧 USB ✅ + auto-reconnect ✅ + S-Pen pen mode ✅; discovery & controls next |

## Quickstart (milestones 1 & 2)

```sh
cd host-macos
./build.sh                     # compile vdhelper (clang only, ~1s)

# create a virtual monitor and hold it for 15 seconds:
./vdhelper --display-only --seconds 15
```

While it runs, open **System Settings → Displays**: a display named
*PhoneDisplay* should appear. You can drag windows onto it. When the helper
stops, the display disappears.

With the Python CLI:

```sh
python3 pdctl.py display --seconds 15                 # 1920×1080
python3 pdctl.py display --width 2400 --height 1080 --hidpi
```

### Streaming to the phone (milestone 2)

```sh
python3 pdctl.py stream            # virtual monitor + H.264 over TCP :8420

# verify from the Mac itself (exactly what the phone app speaks):
python3 ../tools/testclient.py 127.0.0.1

# or pipe one stream to a file and play it:
./vdhelper --stream --seconds 10 > out.bin    # (parsed by pdctl; raw test below)
```

**The virtual display only exists while a phone is connected.** pdctl starts
with no display at all; a phone connecting to :8420 spawns the helper (display
appears within ~1 s), and when the last phone disconnects the display is torn
down again after `--idle-grace` seconds (default 30; short drops and app
restarts therefore do not move your windows around). Pass `--idle-grace 0` if
you want it gone the moment the phone leaves.

On the first run macOS will ask for **Screen Recording** permission (or you can
pre-grant it: System Settings → Privacy & Security → Screen Recording → enable
your terminal app, then restart the terminal). No permission yet? Use the test
pattern — same network/encode path, no capture:

```sh
python3 pdctl.py stream --synthetic
```

## Android app (milestone 3)

Location: `android/` — Kotlin, zero third-party dependencies, hardware decoding
via `MediaCodec`, fullscreen `SurfaceView`, auto-reconnect, screen kept awake.

In-app **60/90 fps selector**: hidden by default while streaming — tap the
top-left corner (invisible hotspot), or tap it with the pen, to reveal the pill;
it fades out again by itself after 4 s (about 1.5 s after you make a choice).
On the connect screen it stays visible. The choice is saved, applied live to the running
stream, and re-sent automatically on every (re)connect — the host caps its
capture rate accordingly (≈66 and ≈91 fps as measured, since the panel
quantizes to display ticks). The host's `--fps`/`--refresh` remain the ceiling
the selector can cap below.

```sh
cd android
./gradlew assembleDebug        # → app/build/outputs/apk/debug/app-debug.apk

# install once the phone is connected (see one-time setup below):
~/Library/Android/sdk/platform-tools/adb install -r app/build/outputs/apk/debug/app-debug.apk
```

### USB mode (recommended — lowest latency, no Wi-Fi needed)

On the Mac:

```sh
cd host-macos
python3 pdctl.py usb           # sets up: adb reverse tcp:8420 tcp:8420
python3 pdctl.py usb --watch   # optional: keeps the tunnel armed across replugs
python3 pdctl.py stream        # add --synthetic for a test pattern
```

Open **PhoneDisplay** on the phone (it already suggests `127.0.0.1:8420`) and
tap Connect — or do nothing: the app auto-connects on launch. `adb reverse`
tunnels that port over the USB cable to the Mac.

### Wi-Fi mode

`python3 pdctl.py stream` prints the Mac's address (e.g. `172.29.204.21:8420`).
Type it into the app and connect. Same network required; USB is faster and more
stable.

### One-time phone setup

1. Settings → About phone → tap **Build number** 7× (enables Developer options)
2. Settings → Developer options → enable **USB debugging**
3. Plug in the cable; tap **Allow** on the phone's prompt
4. If the Mac still sees no device: swap the USB mode to *File transfer*, or
   try another cable (some cables are charge-only)

### S-Pen mode (drive the Mac with the stylus)

Take the S-Pen out of its silo and it becomes the Mac's mouse:

| Pen gesture | Mac effect |
|---|---|
| hover the tip over the glass | pointer moves (no contact needed) |
| tap the tip | left click |
| hold the side button + tap | right click |
| tip down + drag | drag (button stays down until you lift) |
| your palm / fingers | ignored while the pen is out |

Put the pen back in the silo and finger control returns immediately. While
pen mode is on, a small white dot shows at the top-right edge.

How it works: pen events travel to the host as tiny input packets (10 bytes
each) over the same TCP link; the helper injects real macOS mouse events at
the virtual display's position. Hover-to-move needs no contact, so the pen
can rest on the glass without clicking anything.

Notes:

- **Clicks need a one-time grant for the app you launch the stream from.**
  macOS attributes input injection to the terminal app hosting the process
  tree (the "responsible process"), *not* to `vdhelper`. Enable once:
  System Settings → Privacy & Security → **Device Control and Data Access**
  (macOS 26+ name for the Accessibility permission) → turn on your terminal
  app (e.g. **Terminal**, iTerm, Ghostty…). Rebuilding `vdhelper` does not
  invalidate this, because the grant belongs to the terminal app. Pointer
  movement works without the grant; clicks are silently dropped until it is on.
- Detach detection uses Samsung's `com.samsung.pen.INSERT` broadcast; the first
  stylus event also switches pen mode on. In every case pen mode turns itself
  off after 20 s without stylus activity, so a missed "pen inserted" broadcast
  can never lock fingers out. Leaving the hover range, or losing the link,
  while a button is held releases it explicitly.
- The fps HUD stays reachable with the pen: a *tip* gesture that starts in the
  top-left hotspot (or on the open pill) goes to the UI instead of the Mac;
  hover still moves the Mac pointer, so the corner is not a dead zone.
- If the pen's side button pops up Samsung's **Air command** menu, turn it
  off: Settings → Advanced features → S Pen → Air command.
- Mouse-level equivalence only — pressure and tilt are not forwarded.

### High frame rates (90–110 fps)

```sh
python3 pdctl.py stream --width 3120 --height 1440 \
    --refresh 110 --fps 110 --bitrate 35
```

Both the virtual display refresh *and* the stream fps must be set. Measured
end-to-end (capture → encode → USB → phone decode), zero-ish drops
(<0.2%):

| Mode | Sustained | Notes |
|------|-----------|-------|
| 90 Hz / 90 fps | 90.0 fps | comfortable |
| 100 Hz / 100 fps | 99.5 fps | comfortable |
| 110 Hz / 110 fps | ≈106 fps | **max stable** (the display's own composite rate lands ~106) |
| 120 Hz / 120 fps | — | **impossible on this hardware**: H.264 encoder output collapses to 0 at 540 Mpx/s; the media engine ceiling sits between 110 and 120 at 3120×1440 |

> **Turn Low Power Mode off** (System Settings → Battery) while streaming:
> LPM throttles WindowServer animations, so windows opened on the virtual
> display visibly stutter (~15 fps) even though the stream still reports
> 60–90 fps. The stream stats stay healthy — it's the Mac-side rendering.

One catch, fixed in the helper: with `minimumFrameInterval` set exactly at the
panel cadence (e.g. 1/90 on a 90 Hz display), ScreenCaptureKit rejects any
composite that arrives a hair early from vsync jitter — measurably losing ~8%
(90 Hz → only 82.5 fps). The helper now sets the interval 10% *below* the
cadence, which accepts every composite; SCK is change-driven, so a lower gate
never creates extra frames.

Frame rate is demand-driven: static content costs nothing, motion (scrolling,
window drags, video) flows at up to the configured rate. `tools/vdfpswin`
(see below) is a ready-made 90/110 Hz test pattern for verifying the stream.

## Notes & caveats

- **Display identity required**: on current macOS the `CGVirtualDisplayDescriptor`
  must carry a unique `vendorID`/`productID`/`serialNumber` identity — otherwise
  creation fails (returns nil). `vdhelper` derives a **stable** serial from the
  display's name and pixel size, so macOS remembers its arrangement and mode
  across restarts (put PhoneDisplay on the left once and it stays there).
  Different names/sizes get different identities; two instances with the same
  name and size would collide.
- **The streamed mode is pinned.** The display offers 3120×1440, but macOS also
  lists fallback resolutions in Displays. Choosing one scales the captured
  picture while the pen still uses the old pixel grid, so the pointer drifts.
  The helper cannot notice this itself — CoreGraphics only refreshes a
  process's display cache on its run loop — so `pdctl` polls the display from
  outside and restores the target mode with a session configuration, usually
  in under a second and without interrupting the stream. The helper also
  re-applies the mode at startup, so a remembered wrong mode cannot survive a
  reconnect.
- **Private API**: `CGVirtualDisplay` is undocumented. Fine for personal use;
  App Store distribution is not possible with it. If a future macOS removes it,
  the fallback is a DriverKit system extension (much more work).
- **Permissions**: creating the display needs none. Capturing it needs
  **Screen Recording** permission for your terminal (one-time, prompted on the
  first real capture run). Injecting clicks needs **Device Control and Data
  Access** (the Accessibility permission on macOS 26+) for that same terminal
  app — also one-time. `--synthetic` mode bypasses capture entirely.
- **Injected events must carry a click state.** A bare
  `CGEventCreateMouseEvent` event is delivered as a hover: the pointer moves,
  but nothing clicks. `vdhelper` reconstructs the click sequence from the time
  and distance between taps: first down/up = 1, second = 2, third = 3 (so
  double- and triple-click work; a right click resets the sequence). If clicks
  "stop working" after a code change, check this first.
- **The hub is localhost-only by default.** `pdctl stream` binds `127.0.0.1`;
  the USB path only needs that (adb reverse connects on the Mac's loopback).
  `--bind 0.0.0.0` is for Wi-Fi experiments, but the protocol has no
  authentication, so anyone who can reach the port can inject input.
- **First picture on connect (and last picture at rest).** Two decoder facts
  shape this:
  (a) a new client is sent the cached **GOP** — the last keyframe *plus every
  frame after it* — so it sees the exact current picture, not a keyframe that
  can be seconds out of date. The greeting is only sent once a keyframe exists
  (no more empty first picture while the display is still starting), and a
  fresh keyframe is forced once the client is live, so its delta chain is safe
  if a frame went by during the handshake;
  (b) the phone's decoder keeps the newest picture queued until one more input
  arrives. On an idle tick the app re-feeds the last access unit once if no
  output came back, which flushes the final picture of a burst instead of
  leaving it stuck in the codec. Without this, a window that closed on the Mac
  could stay on the phone for minutes.
  Verified on the phone: after a full-screen animation stops, the phone matches
  the Mac display (mean pixel error ~7/255, i.e. H.264 noise).
- **Mac cursor, drawn by the phone**: the pointer is not baked into the video.
  The helper streams tiny cursor packets (~16 bytes, ~60/s while the pointer
  moves, 1/s heartbeat when idle) and the app draws its own pointer at that
  position — so the cursor stays smooth and cheap regardless of the video, and
  it's drawn at **3× the Mac size** by default for comfortable visibility.
  Size is a single value in the app (`CursorView.DEFAULT_SCALE`,
  `cursorScale`, `setCursorScale()`), ready to be hooked up to a settings
  slider later. To go back to the classic baked-in 1× cursor instead, run the
  helper with `--hw-cursor` (pdctl doesn't expose the flag).
- **Idle = silence, but no disruption**: ScreenCaptureKit only emits frames
  when the virtual display's content changes. While idle the phone simply
  keeps showing the last frame and the session stays up — when something
  moves again it resumes instantly, no reconnect. (Even a minutes-long static
  desktop is fine.) Cursor packets keep flowing while the pointer moves; the
  video itself stays silent if nothing else changes. The app's socket read
  ticks every 250 ms, and each idle tick drains the decoder and (once) re-feeds
  the last frame, so the **last** picture of a burst is shown instead of
  staying queued until the next change. A full-screen change (a window closing,
  a virtual desktop switch) is a large burst and can take a couple of seconds
  to finish arriving at the 35 Mbps cap.
- **Test tools**: `tools/vdfpswin` — a full-screen animation window whose
  Core Animation content updates at the display's own refresh rate, i.e. a
  true 90/110 Hz test source (`clang -fobjc-arc -framework Cocoa -framework
  QuartzCore -o vdfpswin vdfpswin.m`; run `~/phonedisplay/tools/vdfpswin`;
  stop with `pkill -f vdfpswin`). `tools/fpstest.html` shows the same kind of
  pattern in a browser (rAF follows the display refresh; no build needed).
- **Keep-awake & self-healing**: `pdctl.py stream` holds the Mac awake via
  `caffeinate` while it runs (opt out with `--no-caffeinate`) and automatically
  restarts the capture helper (~3 s) if macOS kills it — e.g. when the screen
  gets locked — or if it is stopped cleanly with `pkill`. The phone stays
  connected through these restarts (verified: both a helper restart and a full
  pdctl restart recover the display and picture on the same TCP session). If
  pdctl itself dies, the helper sees stdin EOF and removes the virtual display
  instead of leaving a phantom monitor. A client that stops reading for 10 s is
  dropped, so a sleeping phone cannot keep the display alive forever; a
  disconnect while the pen button is held releases the mouse button.
- **Self-test**: `python3 tools/selftest.py --probe <path-to-displayprobe>
  --log host-macos/stream.log` exercises the host protocol end to end:
  handshake, static picture, GOP replay during motion, cursor heartbeat, input
  round-trip, live 60/90 fps change, two clients, and bad-greeting rejection.
  All 8 checks pass.
- **Pixel-perfect on the S24 Ultra**: the phone app draws edge-to-edge,
  including the camera-cutout band, so a 3120×1440 stream maps 1:1 onto the
  physical screen — no black strip, no scaling.
- **Known macOS 27 bug — dragging a *fullscreen* Space to the phone display
  blacks out the built-in display.** This is an OS regression, not a
  PhoneDisplay defect: the same symptom is reported with physical external
  monitors on 27.0/27.0.1 (Apple Community thread 256357160, r/MacOSBeta
  "full screen app turns external/internal display black when dragged via
  Mission Control"). Moving a fullscreen app's Space ("desktop tab") in Mission
  Control makes the source display go black — only the Dock stays — until you
  switch that display to another Space. The Spaces database confirms it:
  `com.apple.spaces` assigns a type-4 (fullscreen) Space to the PhoneDisplay,
  and the built-in's Space entry is left stale. **Workaround:** leave fullscreen
  first (`Ctrl-Cmd-F`), drag the normal window to the phone display, then
  fullscreen it *there* (`Ctrl-Cmd-F` again). A fullscreen Space created on the
  phone display itself is fine; only moving an existing fullscreen Space between
  displays triggers it. No macOS update fixed this as of 27.0.1 (26A434).
- **Display cleanup**: after the helper exits, macOS may take a short while to
  reap the virtual display, and several "PhoneDisplay" entries can briefly
  appear in Displays settings if you crashed earlier runs. They do clear on
  their own; no reboot needed.
- **Multi-monitor**: each `vdhelper` instance creates one extra display; run
  multiple instances for multiple virtual monitors.

## Wire protocol

```
TCP, port 8420; handshake:
  phone → host : "PD01\n"
  host  → phone: "PD01 <width> <height> <fps> <codec>\n"
  then  : repeated packets, in both directions:
            uint32_be length
            uint8     flags (bit0: keyframe; bit1: cursor packet; bit2: input event;
                              bit3: control)
            uint8[length] payload:
              - video:  Annex-B H.264 access unit (keyframes embed SPS/PPS)
              - cursor: uint8 visible | int32_be x | int32_be y
                        (9 bytes, virtual-display pixel coordinates)
              - input : uint8 kind (0 = move, 1 = button down, 2 = button up)
                        | uint8 buttons (bit0 = secondary / pen side button)
                        | int32_be x | int32_be y
                        (10 bytes, phone → host; injected as real macOS mouse events)
              - control: uint8 cmd | uint8 arg
                        cmd 1 = capture frame-rate cap (arg = fps, the phone's
                        60/90 selector); applied live via SCK's
                        minimumFrameInterval, re-applied after helper restarts
```

New clients immediately receive the current **GOP** (the last keyframe plus the
frames that followed it) and the cursor packet, so the picture and pointer
appear without waiting for new updates — current even if the screen has been
static since the last keyframe. Input packets are read independently of video
flow, so a client that is slow to consume video still controls the Mac
immediately; a fresh keyframe is forced once the client is live.

(Internal helper→pdctl header: `PDH1 <w> <h> <fps> <codec> <display-id>`; the
display ID feeds the resolution watchdog and never reaches the phone.)
