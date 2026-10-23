# Next session — resume notes

**Status: post-audit hardening implemented — all 20 findings from the second
audit are in the working tree; host, helper and app build. Host selftest is 8/8
with `--probe` and a live stream log; the app is connected over USB at
3120×1440 / 90 fps with the token, and the 3× cursor is visible. The physical
S-Pen 25 s idle-off and held-tip tests are still manual/unverified.**

## Post-audit hardening (current pass)

- **Auth**: first stream creates `~/.phonedisplay-token` (0600); clients send
  `PD01 <token>`; app uses `host:port#token`; `--token` overrides. Bad/missing
  tokens are closed before any input task.
- **Host**: max 4 clients; 15 s heartbeat watchdog; 10 s writer drain; helper
  stdout 15 s first frame then 5 s; async input with backpressure; GOP
  `need_keyframe`/`request_keyframe` recovery; greeting `ValueError` /
  `LimitOverrunError` handling; `usb --watch` checks its return; prints the
  tokenized USB/LAN string.
- **Helper**: releases a held button on stdin EOF, SIGINT/SIGTERM, display
  termination, SCK stop, stdout failure, and auto-exit; held state is atomic.
- **App**: token parse before connect; `sockOut` only after the greeting; 5 s
  heartbeat; `@Volatile sessionId` checks; Connect disabled while starting;
  stale input queue cleared; decoder released on configure/start failure;
  wait-for-keyframe after a feed failure; overlay tip routing; held-tip timer
  reschedule; dead cursor/read code removed.
- **Tools/docs**: selftest asserts both clients receive video and reports real
  `SKIP`; testclient reads the token; lint `abortOnError false` removed;
  Gradle wrapper uses Homebrew JDK when `JAVA_HOME` is unset; README updated.
- **Verified**: selftest 8/8 (probe + live log), token accepted, app live over
  USB at 3120×1440/90, cursor `visible=true` on the virtual display, host kept
  the client past the 15 s watchdog.
- **Pending (needs the physical pen)**: 25 s idle-off timer and held-tip
  behavior. Do not mark these passed from `adb shell input stylus` — it is
  ignored by this build.

## Full-pipeline audit (previous pass)

Instead of another round of whack-a-mole, the whole pipeline was read end to
end, every found defect fixed at once, and a repeatable protocol suite added.

### A. Picture correctness

1. **Stale last frame at rest** — the phone could freeze on an old picture for
   minutes after a burst. The 250 ms idle tick only helps if the codec has
   already produced an output; the Qualcomm decoder keeps the newest picture
   queued until one more input arrives. The app now re-feeds the last access
   unit when an idle drain returns nothing (max 3), flushing the held picture.
   Verified: stop a full-screen animation → phone matches the Mac display
   (mean pixel error ~7/255 = H.264 noise).
2. **Reconnect could show an out-of-date keyframe** — pdctl cached only the
   last keyframe, so a client connecting after a change saw a picture up to
   2 s old — forever on a static screen. pdctl now caches the whole **GOP**
   (keyframe + every frame after it) and replays it on connect.
3. **Empty-GOP race** — the greeting was sent when the helper printed its
   header, before any frame existed. A client connecting in that window got a
   greeting and then nothing until the next screen change. `header_ready` is
   now set by the **first keyframe**, not the header line.
4. **Fresh keyframe on join** — a frame or two can be broadcast while a
   client's GOP drains, leaving a hole in its delta chain until the next 2 s
   keyframe. The helper accepts `K` on stdin and forces a keyframe on the next
   captured frame; pdctl sends it once the client is live.

### B. Host input & liveness

5. **Pen input stalled behind video** — the input reader started only after the
   cached GOP was flushed, so a client slow to read video had its pen events
   ignored. Input is now read *before* the picture handshake, independently.
6. **Dead client kept the display alive forever** — `writer.drain()` had no
   timeout. Now 10 s → the client is dropped and idle grace can remove the
   display.
7. **Disconnect mid-drag left the Mac button down** — pdctl tracks each
   client's held button and releases it on disconnect.
8. **Clean helper exit killed the server** — `pkill vdhelper` made pdctl exit.
   Now it restarts the helper in 3 s. A hung helper gets SIGKILL after 5 s.
9. **Phantom display if pdctl died** — the helper now exits on stdin EOF, so
   the display is removed even after SIGKILL (verified: gone within 3 s).

### C. Android app

10. **Two stream threads** — `startStreaming()` could leave the old worker
    alive (Connect / surface recreation race); both loops then fought over the
    socket and input. A session id now invalidates the old worker.
11. **Greeting/input ordering** — `sockOut` was published before `PD01\n` was
    written, so an early pen packet could precede the handshake. The greeting
    is written first, under the same lock as input.
12. **Pen mode could stay on forever** — auto-off only applied when a stylus
    event (not Samsung's broadcast) had enabled it. It now applies to every
    source, so a missed "pen inserted" broadcast can never lock fingers out.
13. **HOVER_EXIT could stick a button** — it now releases a held button.
14. **fps HUD unreachable with the pen** — tip gestures starting in the
    hotspot/pill now go to the UI; hover still moves the Mac pointer.
15. **Greeting timeout** — the on-demand display can exceed 5 s on a cold
    start; the greeting read now allows 15 s (TCP connect stays 5 s).
16. **Per-frame 25 ms stall** — the pre-read drain could throttle the loop;
    draining now happens only on idle ticks.
17. **Display rearranged while streaming** — `vdhelper` cached the virtual
    display's bounds at startup for the cursor overlay and pen input. Moving the
    display in System Settings → Displays → Arrange then offset both (observed
    live: `(1470,0)` → `(-3120,-228)`, so input landed ~4.6k px away). Bounds
    are now queried with `CGDisplayBounds` on every cursor tick and input event,
    so a rearrangement takes effect immediately.
18. **Double-click was impossible** — every injected event carried
    `kCGMouseEventClickState = 1`, so two quick taps were two single clicks.
    The helper now reconstructs the sequence from time + distance (1/2/3),
    stamps the up with the same state, and resets on a right click. Verified
    with a listen-only event tap: before `1,1`, after `1,1,2,2`.
19. **Hub was exposed to the LAN** — `pdctl stream` bound `0.0.0.0` by default
    and the protocol had no auth (it injects input). The default is now
    `127.0.0.1`; adb reverse only needs the loopback. Every client must also
    send `PD01 <token>` from `~/.phonedisplay-token` (0600; `--token`
    overrides). `--bind 0.0.0.0` is opt-in and still token-gated. `lsof`
    confirms `TCP 127.0.0.1:8420 (LISTEN)`.
20. **Arrangement reset on every restart** — a random display serial made macOS
    treat each run as a brand-new monitor, so the user's layout (phone display
    on the left) reset every time. The serial is now derived from the display
    name + pixel size, so the arrangement and mode are remembered. Verified:
    `(-3120,-278)` survived a full helper+pdctl restart (display 89 → 90).

`build.sh` also ad-hoc signs the `.app` bundle again.

## Audit test results

- `tools/selftest.py` — **8/8** with `--probe` and a live log: handshake,
  static picture (keyframe + second frame), GOP replay during motion, cursor
  heartbeat, input round-trip exact, live 60→90 fps, two clients (both receive
  video), bad greeting rejected. Missing probe/log shows `SKIP`, not pass.
- Cold start: first output **107–141 ms** after the greeting.
- Rearrangement handling: after the live-bounds fix, input round-trip is exact
  at the current origin (`(1593,456)` = expected); bounds are no longer cached.
- Double-click: event tap shows `1,1,2,2` for two taps (was `1,1,1,1`).
- Display position: `(-3120,-278)` survived a full helper+pdctl restart.
- Bind: `lsof` shows `TCP 127.0.0.1:8420 (LISTEN)` only.
- Animation stop: phone vs Mac display **MAE 7.3/255** (compression noise).
- Helper kill: new helper + display in 3 s, app never disconnected, picture
  exact.
- pdctl kill: helper exited via stdin EOF, display removed; restart → app
  reconnected in ~7 s, display recreated, picture exact.
- Idle grace: display present at +10 s, gone at +35 s, back on relaunch.
- Resolution change (2026-10-23): switching PhoneDisplay to 1920×886 or
  1280×590 mid-stream snaps back to 3120×1440 in **under 0.7 s**, with the same
  display ID and helper process; the app keeps decoding (60–80 fps, 0
  dropped). `pdctl` watches the mode from outside because the display owner
  cannot see the change. Selftest 8/8, input exact `(-2997,178)`, phone vs Mac
  **MAE 2.4/255**.
- 90 fps sustained (earlier, still valid): 89–94 fps decoded, 0 dropped.

## Earlier fixes (Oct 20)

### 1. The permission was granted to the wrong app
macOS attributes Accessibility / input-injection permission to the **hosting
app** (the terminal running OpenCode / pdctl) — the "responsible process" —
**not** to the spawned `vdhelper`. Granting `vdhelper` in System Settings did
nothing; the helper kept logging "macOS is not letting vdhelper post click
events".

Correct one-time grant:
System Settings → Privacy & Security → **Device Control and Data Access**
(macOS 26+ name for the Accessibility pane) → turn on the **terminal app**
(e.g. **Terminal**).

Side benefits: helper rebuilds/re-signs no longer invalidate the permission,
and the `vdhelper` list entry is unnecessary (can stay, harmless).
Verify with the helper's startup line — it must say `granted`:

```sh
grep -a "input injection armed" ~/phonedisplay/host-macos/stream.log | tail -1
```

### 2. Injected clicks were delivered as hovers
`CGEventCreateMouseEvent` alone is not enough: without
`kCGMouseEventClickState = 1` macOS moves the pointer but never activates
buttons/menus. `vdhelper.m` (`injectInputKind:`) now sets it on every event.
Verified: protocol right-click opens the desktop context menu on the virtual
display; left-click dismisses it.

### 3. Low Power Mode was on
`lowpowermode 1` throttled window animations → apps opened on the phone
display looked like ~15 fps even though the stream ran at 60. Turn it off
(System Settings → Battery) when streaming. Documented in README.

### 4. Phantom display with no phone attached
The helper (and its virtual display) used to be spawned at pdctl startup and
kept forever. pdctl now starts **no** display; a phone connecting to :8420
starts the helper on demand, and the display is removed after `--idle-grace`
seconds (default 30) with no clients. Verified: no display when idle; display
appears ~1 s after connect (first frame 0.74 s); gone ~6 s after disconnect
with `--idle-grace 6`. A helper that fails to start now retries instead of
killing the server.

### 5. Black phone screen on connect (static desktop)
The app decoded nothing until the Mac screen changed. Two causes, both fixed:
- The Qualcomm decoder only flushes its first picture when a **second frame**
  arrives; the app drained output with a 0 ms timeout right after feeding a
  frame, so on a change-driven stream (static screen = no more frames) the
  picture never came out. `drainDecoder` now takes a wait timeout and the loop
  blocks (≤400 ms per frame) until the first output is released.
- pdctl re-sends the cached keyframe once **0.5 s after the handshake**
  (`_nudge_keyframe`), so the decoder always gets that second frame even when
  nothing on the Mac moves.
Verified: cold start shows the desktop in ~1.2 s; reconnects to an unchanged
static screen show it too (previously black with just the cursor).

### 6. Stale picture when the Mac screen goes still
Found during phone testing: after a burst of frames (e.g. a window closing),
the phone kept showing an old frame — sometimes for over a minute. The decode
thread blocks in `readFrameHeader()` waiting for the next packet, so the
`drainDecoder()` call never runs and the **last** frame of the burst stays
queued in the codec. Fixed: the socket read now ticks every 250 ms; an idle
tick returns an empty header, the loop flushes the decoder and blocks again.
Mid-packet reads tolerate the short timeout up to a 10 s stall budget before
declaring the link dead. Verified: window close → wallpaper on the phone
within ~2–4 s (time for the full-screen change to arrive at the 35 Mbps cap),
no more indefinite stale frames.

pdctl's per-client queue also grew 8 → 48 frames and now reports `drops=` in
the stats line (0 during a 90 fps test), so queue backpressure is visible.

## Test results (Oct 20, automated end-to-end)

- USB link, phone-side sustained test at 90 fps cap: **89–94 fps decoded,
  0 dropped frames**, host encodes 90–93 fps at ~5 Mbps (`vdfpswin` motion on
  the virtual display, ~1600 frames). Link is healthy; `drops=0`.
- Move injection: pointer lands exactly at origin+local (verified via
  `displayprobe`, e.g. local 1560,700 → global 3030,700).
- Left/right click through the full protocol: right-click opened the desktop
  context menu on the virtual display, left-click dismissed it (screenshots).
- Cursor overlay on the phone: phone screenshot shows the arrow exactly at the
  injected local coordinates (800,400 → scaled 256,128).
- fps control: 60 → 90 applied live by the helper (`capture rate → 90 fps`).
- Display lifecycle: no client → no display; connect → display at (1470,0);
  force-stop app → display removed after 30 s; helper gone.
- Real phone: app connects over adb reverse, decoder starts, desktop visible,
  cursor overlay tracking, `first output after ~120–150 ms`.
- App pref is **90 fps**.

## Still to verify / build

0. ~~**The phone fell off the USB bus**~~ — reconnected 2026-10-23
   (`adb devices` shows `RZCY40VEZYT`); the app is running and streaming.
   If you rebuild the APK, install it:
   `adb install -r android/app/build/outputs/apk/debug/app-debug.apk`.
1. **Pen test** (pen in hand, Air Command OFF):
   `adb logcat -s PhoneDisplay:I | grep stylus:` — expect
   `stylus: action=… buttons=… pressure=… -> (x,y)`.
   - hover → cursor moves
   - tip tap → left click
   - drag → window drag
   - **side button held + tip tap → right click** (buttons bit0)
2. **If the side button never reports `buttons`≠0** (Samsung Air Command eats
   it): build the app-side fallback — tip long-press (~600 ms without moving)
   → right click.
3. ~~**Black Mac screen when dragging an app onto the phone display**~~ —
   **diagnosed 2026-10-21: macOS 27.0.1 bug, not ours.** Captured state at
   00:38:55 IST: Spotify's window is fullscreen at `(1470,0 3120×1440)` and
   `com.apple.spaces` has a **type-4 fullscreen Space (id 1275) assigned to the
   PhoneDisplay** (`4020D9AA…`), while the built-in ("Main", `37D8…`) was left
   on a stale Space and rendered black until the user picked another desktop.
   The same blackout is reported with **physical** external monitors on
   macOS 27.0/27.0.1 (r/MacOSBeta `1wcf6pw`; Apple Community thread
   `256357160`; HomeTechOps runbook, reviewed 2026-10-17). Apple has no fix;
   `softwareupdate -l` shows 27.0.1 is current. **Workaround:** exit fullscreen
   (`Ctrl-Cmd-F`), drag the *window* to the phone display, then fullscreen it
   there. Never drag a fullscreen Space between displays. Re-check after a
   macOS 27.x update; no code change can prevent it.

## Banked (deliberately deferred)

- Cursor-size slider (cursor is fixed at 3×; `CursorView.DEFAULT_SCALE`).
- Finger-touch input (pen mode ignores fingers by design).
- Wi-Fi transport, Windows host.

## Current running state

- Stream: `--width 3120 --height 1440 --refresh 110 --fps 110 --bitrate 35`
  (idle grace 30 s, the default), app caps the capture rate live (90).
- **No phone connected → no virtual display.** The display is created when the
  app (or a probe) connects and removed 30 s after the last client leaves.
  If it ever lingers, check `pgrep -fl vdhelper`.
- `pdctl.py usb --watch` armed; `adb reverse tcp:8420 tcp:8420` present.
- When the phone is connected the virtual display is display 2, 3120×1440,
  wherever Arrange put it (currently left of the built-in at `(-3120,-278)`).
  The arrangement is restored automatically, and `pdctl` undoes a resolution
  change within ~2 s without restarting the stream. Direct capture check:
  `screencapture -x -D2 /tmp/vd.png`.
- Helper is properly signed (ad-hoc) and reports `granted`.
- `tools/selftest.py` is the regression gate:
  `python3 tools/selftest.py --probe <displayprobe> --log host-macos/stream.log`.

## Restart (if dead)

```sh
cd ~/phonedisplay/host-macos
nohup python3 pdctl.py stream --width 3120 --height 1440 --refresh 110 --fps 110 --bitrate 35 >> stream.log 2>&1 & disown
```

The stream prints `USB: 127.0.0.1:8420#<token>`; the app's saved host must
include `#<token>` (token file: `~/.phonedisplay-token`, 0600).

If you are restarting it from an agent/tool shell that kills its process group
when the command returns, detach it into a new session instead:

```sh
python3 - <<'EOF'
import subprocess
log = open("/Users/pixiii/phonedisplay/host-macos/stream.log", "ab")
subprocess.Popen(["python3", "pdctl.py", "stream", "--width", "3120", "--height", "1440",
                  "--refresh", "110", "--fps", "110", "--bitrate", "35"],
                 cwd="/Users/pixiii/phonedisplay/host-macos",
                 stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                 start_new_session=True)
EOF
```

Open **PhoneDisplay** on the phone — auto-connects and applies its saved fps.

## Useful probes (in /private/var/folders/.../T/opencode)

- `tccprobe` — prints `CGPreflightPostEventAccess`.
- `axprobe` — prints post-event + `AXIsProcessTrusted`.
- `displayprobe` — display arrangement + pointer position.
- `winlist` — windows on the virtual display (great for verifying menus open).
- `rclick x y` / `clickprobe2 x y tap` — raw injection tests on global coords.

## Notes

- No version control; everything lives in the working tree. README updated
  (host-app permission, click-state requirement, Low Power Mode).
