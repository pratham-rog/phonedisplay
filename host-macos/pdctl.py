#!/usr/bin/env python3
"""
pdctl — PhoneDisplay control utility (macOS host side).

Drives the native helper (vdhelper):

    build    compile it
    display  show a virtual second monitor only
    stream   virtual monitor + H.264 capture + TCP server for the phone

Default listen port: 8420 (TCP).

The phone connects, sends "PD01 <token>\n", gets back "PD01 <w> <h> <fps> h264\n",
then receives length-prefixed Annex-B H.264 frames until disconnect.

The link is bidirectional: the phone may send its own framed packets
(flags 0x04, an input event) which pdctl parses and writes to the helper's
stdin, where they become real macOS mouse events (S-Pen mode).
"""
import argparse
import asyncio
import contextlib
import ctypes
import hmac
import os
import secrets
import shutil
import socket
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "vdhelper")
# Prefer the binary inside vdhelper.app: that bundle is what the user adds in
# System Settings → Privacy & Security → Accessibility for click injection.
_APP_HELPER = os.path.join(HERE, "vdhelper.app", "Contents", "MacOS", "vdhelper")
if os.path.exists(_APP_HELPER):
    HELPER = _APP_HELPER

FRAME_HDR = struct.Struct(">IB")   # uint32 length | uint8 flags
TOKEN_FILE = os.path.expanduser("~/.phonedisplay-token")


def load_token(explicit: str | None = None) -> str:
    """Shared secret for the input-injection link; generated once at 0600."""
    if explicit:
        return explicit.strip()
    try:
        with open(TOKEN_FILE, encoding="ascii") as f:
            token = f.read().strip()
    except FileNotFoundError:
        token = ""
    if not token:
        token = secrets.token_urlsafe(24)
        fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="ascii") as f:
            f.write(token + "\n")
    else:
        with contextlib.suppress(OSError):
            os.chmod(TOKEN_FILE, 0o600)
    return token

# --- display-mode watchdog -------------------------------------------------
# CoreGraphics refreshes a process's display cache through its run loop. The
# helper owns the virtual display and does not observe an external resolution
# change, but this process does. Poll the mode and put it back, so a stray
# choice in Displays cannot desync the pen from the picture.
_cg = None


def _coregraphics():
    global _cg
    if _cg is None:
        try:
            cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
            cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
            cg.CGDisplayCopyDisplayMode.restype = ctypes.c_void_p
            cg.CGDisplayCopyDisplayMode.argtypes = [ctypes.c_uint32]
            cg.CGDisplayCopyAllDisplayModes.restype = ctypes.c_void_p
            cg.CGDisplayCopyAllDisplayModes.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
            for name in ("CGDisplayModeGetPixelWidth", "CGDisplayModeGetPixelHeight"):
                fn = getattr(cg, name)
                fn.restype = ctypes.c_size_t
                fn.argtypes = [ctypes.c_void_p]
            cf.CFArrayGetCount.restype = ctypes.c_long
            cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
            cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
            cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
            cf.CFRelease.restype = None
            cf.CFRelease.argtypes = [ctypes.c_void_p]
            cg.CGBeginDisplayConfiguration.restype = ctypes.c_int32
            cg.CGBeginDisplayConfiguration.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
            cg.CGConfigureDisplayWithDisplayMode.restype = ctypes.c_int32
            cg.CGConfigureDisplayWithDisplayMode.argtypes = [
                ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p]
            cg.CGCompleteDisplayConfiguration.restype = ctypes.c_int32
            cg.CGCompleteDisplayConfiguration.argtypes = [ctypes.c_void_p, ctypes.c_int32]
            cg.CGCancelDisplayConfiguration.restype = ctypes.c_int32
            cg.CGCancelDisplayConfiguration.argtypes = [ctypes.c_void_p]
            _cg = (cg, cf)
        except (OSError, AttributeError):
            _cg = False
    return _cg or None


def display_pixel_size(display_id: int):
    libs = _coregraphics()
    if libs is None or not display_id:
        return None
    cg, cf = libs
    mode = cg.CGDisplayCopyDisplayMode(display_id)
    if not mode:
        return None
    try:
        return (cg.CGDisplayModeGetPixelWidth(mode),
                cg.CGDisplayModeGetPixelHeight(mode))
    finally:
        cf.CFRelease(mode)


def restore_display_mode(display_id: int, width: int, height: int) -> bool:
    """Set the display back to the streamed size. This process is not the
    display's owner, so a session configuration works here; the helper's own
    CGDisplaySetDisplayMode silently has no effect after an external change."""
    libs = _coregraphics()
    if libs is None or not display_id:
        return False
    cg, cf = libs
    modes = cg.CGDisplayCopyAllDisplayModes(display_id, None)
    if not modes:
        return False
    try:
        want = None
        for i in range(cf.CFArrayGetCount(modes)):
            mode = cf.CFArrayGetValueAtIndex(modes, i)
            if (cg.CGDisplayModeGetPixelWidth(mode),
                    cg.CGDisplayModeGetPixelHeight(mode)) == (width, height):
                want = mode
                break
        if not want:
            return False
        cfg = ctypes.c_void_p()
        if cg.CGBeginDisplayConfiguration(ctypes.byref(cfg)) != 0:
            return False
        if cg.CGConfigureDisplayWithDisplayMode(cfg, display_id, want, None) != 0:
            cg.CGCancelDisplayConfiguration(cfg)
            return False
        return cg.CGCompleteDisplayConfiguration(cfg, 1) == 0   # kCGConfigureForSession
    finally:
        cf.CFRelease(modes)


# ---------------------------------------------------------------- helpers

def lan_ip() -> str | None:
    """Best-effort local network address (the one the phone should dial)."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return None


def run(cmd: list[str]) -> int:
    print("$", " ".join(cmd), flush=True)
    try:
        return subprocess.run(cmd).returncode
    except KeyboardInterrupt:
        print("\nstopped.")
        return 0


# ---------------------------------------------------------------- commands

def cmd_build(_args) -> int:
    return run([os.path.join(HERE, "build.sh")])


def usb_watch(adb: str, port: int) -> int:
    """Keep the USB tunnel armed: re-arm it whenever the phone (re)appears."""
    want = f"tcp:{port} tcp:{port}"
    print("watching USB — the tunnel is (re)armed automatically whenever the phone")
    print("shows up (plug/unplug/replug is fine).  Leave this running; Ctrl-C to stop.")
    state = None
    try:
        while True:
            out = subprocess.run([adb, "devices"], capture_output=True, text=True).stdout
            lines = [l for l in out.splitlines() if "\t" in l]
            if any(l.endswith("\tdevice") for l in lines):
                new = "online"
            elif any("\tunauthorized" in l for l in lines):
                new = "unauth"
            else:
                new = "gone"

            if new != state:
                if new == "online":
                    print("[+] phone detected", flush=True)
                elif new == "unauth":
                    print("[!] phone present but unauthorized — tap 'Allow USB debugging'",
                          flush=True)
                elif state in ("online", "unauth"):
                    print("[-] phone gone — waiting…", flush=True)
                else:
                    print("[…] waiting for a phone over USB…", flush=True)
                state = new

            if new == "online":
                cur = subprocess.run([adb, "reverse", "--list"],
                                     capture_output=True, text=True).stdout
                if want not in cur:
                    r = subprocess.run([adb, "reverse", want.split()[0], want.split()[1]],
                                       capture_output=True, text=True)
                    if r.returncode == 0:
                        print(f"    tunnel armed:  127.0.0.1:{port} → Mac:{port}", flush=True)
                    else:
                        print(f"[!] tunnel arm failed: {r.stderr.strip() or r.stdout.strip()}",
                              flush=True)

            time.sleep(2)
    except KeyboardInterrupt:
        print("\nstopped.")
    return 0


def cmd_usb(args) -> int:
    """Set up an adb reverse tunnel so the phone can reach this Mac over USB."""
    adb = shutil.which("adb") or os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")
    if not os.path.exists(adb):
        sys.exit("adb not found — install Android platform-tools")

    subprocess.run([adb, "start-server"], capture_output=True)

    if args.watch:
        return usb_watch(adb, args.port)

    out = subprocess.run([adb, "devices"], capture_output=True, text=True).stdout
    print(out.strip())

    lines = [l for l in out.splitlines() if "\t" in l]
    if not lines:
        sys.exit("no phone detected over USB.\n"
                 "  1. On the phone: Settings → About phone → tap 'Build number' 7×\n"
                 "  2. Settings → Developer options → enable USB debugging\n"
                 "  3. Re-plug the cable; tap 'Allow' on the phone's prompt\n"
                 "  4. If the Mac shows nothing, set the USB mode to 'File transfer'")
    if any("\tunauthorized" in l for l in lines):
        sys.exit("phone is connected but UNAUTHORIZED — tap 'Allow USB debugging'\n"
                 "on the phone screen, then re-run this command.")

    subprocess.run([adb, "reverse", f"tcp:{args.port}", f"tcp:{args.port}"], check=True)
    print(f"\nUSB tunnel ready:  phone's 127.0.0.1:{args.port}  →  this Mac's port {args.port}")
    print("Tip: `python3 pdctl.py usb --watch` keeps the tunnel armed across replugs.")
    print("Start the host stream in another terminal:  python3 pdctl.py stream")
    return 0


def helper_args(args) -> list[str]:
    cmd = [HELPER,
           "--width", str(args.width),
           "--height", str(args.height),
           "--refresh", str(args.refresh),
           "--inches", str(args.inches),
           "--name", args.name]
    if getattr(args, "fps", None):
        cmd += ["--fps", str(args.fps)]
    if getattr(args, "bitrate", None):
        cmd += ["--bitrate", str(args.bitrate)]
    if getattr(args, "synthetic", False):
        cmd.append("--synthetic")
    if args.hidpi:
        cmd.append("--hidpi")
    if args.seconds:
        cmd += ["--seconds", str(args.seconds)]
    return cmd


def cmd_display(args) -> int:
    if not os.path.exists(HELPER):
        sys.exit("vdhelper not built yet — run: python3 pdctl.py build")
    return run(helper_args(args) + ["--display-only"])


class Hub:
    """Distributes framed H.264 to all connected phones."""

    MAX_CLIENTS = 4
    CLIENT_SILENCE = 15.0

    def __init__(self, token: str) -> None:
        self.token = token
        self.clients: dict[asyncio.StreamWriter, asyncio.Queue] = {}
        self.not_ready: set[asyncio.StreamWriter] = set()  # handshake in progress
        self.need_keyframe: set[asyncio.StreamWriter] = set()
        self.client_state: dict[asyncio.StreamWriter, dict] = {}
        self.keyframe_requested = False
        self.header_line = b""
        self.header_ready = asyncio.Event()     # a helper session is up
        self.idle_stopped = False               # helper stopped: nobody watching
        self.gop: list[bytes] = []              # latest keyframe + follow-up frames
        self.gop_bytes = 0                      # instant, up-to-date picture on connect
        self.last_cursor: bytes | None = None     # instant pointer for new clients
        self.helper_in: asyncio.StreamWriter | None = None   # current helper's stdin
        self.logged_input = False
        self.requested_fps: int | None = None   # phone-chosen capture rate cap
        self.drops = 0                          # frames dropped for slow clients

    def reset_session(self) -> None:
        """Forget the helper session: its virtual display no longer exists."""
        self.header_line = b""
        self.header_ready.clear()
        self.gop = []
        self.gop_bytes = 0
        self.last_cursor = None
        self.need_keyframe.clear()
        self.keyframe_requested = False

    def remember_frame(self, packet: bytes, keyframe: bool) -> None:
        """Keep the newest GOP so a client that connects now sees the exact
        current picture — not just the last keyframe (up to 2 s older)."""
        if keyframe:
            self.gop = [packet]
            self.gop_bytes = len(packet)
        elif self.gop:
            self.gop.append(packet)
            self.gop_bytes += len(packet)
            if len(self.gop) > 500 or self.gop_bytes > (16 << 20):
                # too much to replay; wait for the next keyframe instead of
                # shipping a chain with a hole in it
                self.gop = []
                self.gop_bytes = 0

    def _drop_client(self, writer: asyncio.StreamWriter) -> None:
        """Remove a client and wake its video loop; idempotent."""
        q = self.clients.pop(writer, None)
        self.not_ready.discard(writer)
        self.need_keyframe.discard(writer)
        self.client_state.pop(writer, None)
        if q is not None:
            with contextlib.suppress(asyncio.QueueFull):
                q.put_nowait(None)          # sentinel: stop the live loop
        with contextlib.suppress(Exception):
            writer.close()

    async def handle_client(self, reader: asyncio.StreamReader,
                            writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername")
        try:
            greeting = await asyncio.wait_for(reader.readline(), timeout=5)
        except (asyncio.TimeoutError, ValueError, asyncio.LimitOverrunError):
            writer.close()
            return
        parts = greeting.strip().split()
        if (len(parts) != 2 or parts[0] != b"PD01" or
                not hmac.compare_digest(parts[1], self.token.encode())):
            print(f"[-] {peer[0]}:{peer[1]} sent a bad greeting", flush=True)
            writer.close()
            return
        if len(self.clients) >= self.MAX_CLIENTS:
            print(f"[-] {peer[0]}:{peer[1]} rejected: "
                  f"{self.MAX_CLIENTS} clients already connected", flush=True)
            writer.close()
            return
        print(f"[+] {peer[0]}:{peer[1]} connected", flush=True)

        q: asyncio.Queue = asyncio.Queue(maxsize=48)
        state = {"held": -1, "x": 0, "y": 0, "last_seen": time.monotonic()}
        self.clients[writer] = q      # wakes the session loop: start the display
        self.client_state[writer] = state
        self.not_ready.add(writer)    # no live frames queued until the GOP is out

        # Input and heartbeat must be read before the picture handshake: a
        # client waiting for the display must not look dead.
        input_task = asyncio.create_task(
            self._client_inputs(reader, writer, peer, state))
        watchdog = asyncio.create_task(self._client_watchdog(writer, state))
        try:
            # the virtual display is created on demand, give the helper a moment
            await asyncio.wait_for(self.header_ready.wait(), timeout=15)
        except asyncio.TimeoutError:
            print(f"[-] {peer[0]}:{peer[1]} gave up waiting for the stream to start")
            input_task.cancel()
            watchdog.cancel()
            self._drop_client(writer)
            return

        try:
            writer.write(self.header_line)
            sent = 0
            for packet in self.gop:            # exact current picture
                writer.write(packet)
                sent += len(packet)
                if sent >= (256 << 10):        # bound the transport buffer
                    sent = 0
                    await asyncio.wait_for(writer.drain(), timeout=10)
            if self.last_cursor:
                writer.write(self.last_cursor)
            await asyncio.wait_for(writer.drain(), timeout=10)
        except (ConnectionError, asyncio.TimeoutError, asyncio.CancelledError):
            input_task.cancel()
            watchdog.cancel()
            self._drop_client(writer)
            print(f"[-] {peer[0]}:{peer[1]} dropped during handshake")
            return
        self.not_ready.discard(writer)

        # Ask the helper for a fresh keyframe now that this client is about to
        # receive live frames. A frame or two may have been broadcast while its
        # GOP was draining; the keyframe makes the delta chain safe again.
        helper_in = self.helper_in
        if helper_in is not None:
            try:
                helper_in.write(b"K\n")
            except (ConnectionError, RuntimeError):
                self.helper_in = None

        # a static screen has a one-frame GOP; the decoder needs a second frame
        # before it flushes the first one, so repeat that single frame once
        asyncio.create_task(self._nudge_keyframe(writer, q))
        try:
            while True:
                packet = await q.get()
                if packet is None:              # input EOF / watchdog / cap
                    break
                writer.write(packet)
                # a client that stops reading (phone asleep, USB gone) must not
                # keep the display alive forever: drop it after 10 s
                await asyncio.wait_for(writer.drain(), timeout=10)
        except asyncio.TimeoutError:
            print(f"[-] {peer[0]}:{peer[1]} stopped reading — dropping it", flush=True)
        except (ConnectionError, asyncio.CancelledError):
            pass
        finally:
            input_task.cancel()
            watchdog.cancel()
            self._drop_client(writer)
            print(f"[-] {peer[0]}:{peer[1]} disconnected", flush=True)

    async def _client_watchdog(self, writer: asyncio.StreamWriter, state: dict) -> None:
        """Drop a client that stopped sending heartbeats/input (e.g. USB yanked)."""
        while writer in self.clients:
            await asyncio.sleep(1.0)
            if writer not in self.clients:
                return
            if time.monotonic() - state["last_seen"] > self.CLIENT_SILENCE:
                print(f"[-] client silent for {self.CLIENT_SILENCE:.0f} s — dropping it",
                      flush=True)
                self._drop_client(writer)
                return

    async def _nudge_keyframe(self, writer: asyncio.StreamWriter,
                              q: asyncio.Queue) -> None:
        """On a static screen the cached GOP is a single frame, and the decoder
        only flushes its first picture when a second frame arrives. Repeat it
        once; when the GOP already has several frames the client is fine."""
        await asyncio.sleep(0.5)
        if self.clients.get(writer) is not q:
            return
        gop = self.gop
        if len(gop) != 1:
            return
        with contextlib.suppress(asyncio.QueueFull):
            q.put_nowait(gop[0])

    async def _client_inputs(self, reader: asyncio.StreamReader,
                             writer: asyncio.StreamWriter, peer,
                             state: dict) -> None:
        """Read packets the phone sends back (input + control/heartbeat)."""
        try:
            while True:
                hdr = await reader.readexactly(FRAME_HDR.size)
                length, flags = FRAME_HDR.unpack(hdr)
                if length <= 0 or length > 4096:
                    raise ConnectionError("bogus inbound packet")
                payload = await reader.readexactly(length)
                state["last_seen"] = time.monotonic()
                if flags & 0x04:
                    await self._forward_input(payload, peer, state)
                elif flags & 0x08:
                    self._handle_control(payload, peer)
        except (asyncio.IncompleteReadError, ConnectionError, asyncio.CancelledError):
            pass
        finally:
            try:
                await self._release_held_button(state, peer)
            finally:
                self._drop_client(writer)

    async def _forward_input(self, payload: bytes, peer, state: dict) -> None:
        """Input packet: u8 kind | u8 buttons | int32be x | int32be y."""
        if len(payload) < 10:
            return
        kind, buttons = payload[0], payload[1]
        if kind > 2:
            return
        x = int.from_bytes(payload[2:6], "big", signed=True)
        y = int.from_bytes(payload[6:10], "big", signed=True)
        state["x"], state["y"] = x, y
        if kind == 1:
            state["held"] = buttons & 1
        elif kind == 2:
            state["held"] = -1
        if not self.logged_input:
            self.logged_input = True
            print(f"[+] input events from {peer[0]}:{peer[1]} "
                  f"(first: kind={kind} buttons={buttons} x={x} y={y})", flush=True)
        helper_in = self.helper_in
        if helper_in is None:                 # helper down/restarting: drop
            return
        try:
            helper_in.write(b"I %d %d %d %d\n" % (kind, buttons & 1, x, y))
            # A flooded/slow helper must not grow this buffer without bound.
            await asyncio.wait_for(helper_in.drain(), timeout=1.0)
        except (ConnectionError, RuntimeError, asyncio.TimeoutError):
            self.helper_in = None
            with contextlib.suppress(Exception):
                helper_in.close()             # EOF also releases the helper's button

    async def _release_held_button(self, state: dict, peer) -> None:
        """The app died / the link dropped mid-click: never leave the Mac's
        mouse button pressed."""
        held = state["held"]
        if held < 0:
            return
        state["held"] = -1
        print(f"[!] {peer[0]}:{peer[1]} disconnected with the pen down — releasing it",
              flush=True)
        helper_in = self.helper_in
        if helper_in is None:
            return
        try:
            helper_in.write(b"I 2 %d %d %d\n" % (held, state["x"], state["y"]))
            await asyncio.wait_for(helper_in.drain(), timeout=1.0)
        except (ConnectionError, RuntimeError, asyncio.TimeoutError):
            self.helper_in = None
            with contextlib.suppress(Exception):
                helper_in.close()

    def _handle_control(self, payload: bytes, peer) -> None:
        """Control packet: u8 cmd | u8 arg.
        cmd 1 = capture frame-rate cap; cmd 2 = heartbeat (last_seen is
        refreshed by the reader before this runs)."""
        if len(payload) < 2:
            return
        cmd, arg = payload[0], payload[1]
        if cmd != 1:
            return
        fps = max(10, min(240, arg))
        if fps == self.requested_fps:
            return
        self.requested_fps = fps
        print(f"[+] control: capture rate → {fps} fps "
              f"(requested by {peer[0]}:{peer[1]})", flush=True)
        self.apply_capture_fps()

    def request_keyframe(self) -> None:
        """Ask the helper for one keyframe, coalescing bursts of slow clients."""
        if self.keyframe_requested:
            return
        self.keyframe_requested = True
        helper_in = self.helper_in
        if helper_in is None:
            return
        try:
            helper_in.write(b"K\n")
        except (ConnectionError, RuntimeError):
            self.helper_in = None

    def apply_capture_fps(self) -> None:
        """Push the chosen cap to the helper (re-applied after restarts)."""
        helper_in = self.helper_in
        if helper_in is None or self.requested_fps is None:
            return
        try:
            helper_in.write(b"F %d\n" % self.requested_fps)
        except (ConnectionError, RuntimeError):
            self.helper_in = None

    async def broadcast(self, frame: bytes, keyframe: bool | None = None) -> None:
        if keyframe is True:
            self.keyframe_requested = False
        for writer, q in list(self.clients.items()):
            if writer in self.not_ready:       # handshake: the GOP covers it
                continue
            if q.full():                       # slow client: drop the stale chain
                self.drops += 1
                while not q.empty():
                    with contextlib.suppress(asyncio.QueueEmpty):
                        q.get_nowait()
                self.need_keyframe.add(writer)
                if keyframe is not True:
                    self.request_keyframe()
            if writer in self.need_keyframe:
                if keyframe is None:           # cursor packet: always useful
                    pass
                elif not keyframe:             # wait for a clean starting point
                    continue
                else:
                    self.need_keyframe.discard(writer)
            try:
                q.put_nowait(frame)
            except asyncio.QueueFull:
                self.drops += 1


async def run_stream(args) -> int:
    token = load_token(getattr(args, "token", None))
    hub = Hub(token)
    server = await asyncio.start_server(hub.handle_client, args.bind, args.port)
    ip = lan_ip()
    print(f"listening on {args.bind}:{args.port}")
    print(f"USB: 127.0.0.1:{args.port}#{token}")
    if args.bind in ("0.0.0.0", "::"):
        print(f"LAN: {ip or args.bind}:{args.port}#{token}")
    else:
        print("Wi-Fi: start with --bind 0.0.0.0 to listen on the LAN")
    try:
        return await _stream_sessions(args, hub)
    finally:
        server.close()


async def _watch_idle(hub, proc, grace: float) -> None:
    """Remove the virtual display when no phone has been connected for `grace` s."""
    idle_since = None
    while True:
        await asyncio.sleep(1.0)
        if hub.clients:
            idle_since = None
            continue
        if idle_since is None:
            idle_since = time.monotonic()
        elif time.monotonic() - idle_since >= grace:
            print(f"no phone connected for {grace:.0f} s — removing the virtual display",
                  flush=True)
            hub.idle_stopped = True
            with contextlib.suppress(ProcessLookupError):
                proc.terminate()
            # a wedged helper must not keep the display alive forever
            await asyncio.sleep(3)
            if proc.returncode is None:
                with contextlib.suppress(ProcessLookupError):
                    proc.kill()
            return


async def _watch_display_mode(proc, display_id: int,
                              width: int, height: int) -> None:
    """Put the display back to the streamed size if the user changes it."""
    if not display_id:
        return
    misses = 0
    while True:
        await asyncio.sleep(2.0)
        size = display_pixel_size(display_id)
        if size is None:
            return                      # display gone / being recreated
        if size == (width, height):
            misses = 0
            continue
        print(f"display mode changed to {size[0]}x{size[1]} — restoring "
              f"{width}x{height}", flush=True)
        if await asyncio.to_thread(restore_display_mode, display_id, width, height):
            misses = 0
            continue
        misses += 1
        if misses >= 3:                 # cannot fix it: recreate the display
            print("mode restore failed — restarting the helper", flush=True)
            with contextlib.suppress(ProcessLookupError):
                proc.terminate()
            return


async def _stream_sessions(args, hub) -> int:
    """One helper per viewing session: the virtual display is created when a
    phone connects and removed again after `--idle-grace` seconds without one."""
    grace = max(0.0, getattr(args, "idle_grace", 30.0))
    while True:
        if not hub.clients:
            print("waiting for the phone to connect (virtual display is off)", flush=True)
            while not hub.clients:
                await asyncio.sleep(0.4)

        cmd = helper_args(args) + ["--stream"]
        if not getattr(args, "no_caffeinate", False) and shutil.which("caffeinate"):
            # hold the Mac awake while it is working as the phone's monitor
            cmd = ["caffeinate", "-d", "-i"] + cmd
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE)   # stderr inherits: user sees logs
        hub.helper_in = proc.stdin            # input events → helper → CGEventPost
        watchdog = asyncio.create_task(_watch_idle(hub, proc, grace))

        frames = 0
        win_frames = 0
        win_bytes = 0
        drops_at_last = 0
        t0 = time.monotonic()
        started = False
        mode_task = None
        try:
            # helper prints one ASCII header line before the binary stream
            line = await asyncio.wait_for(proc.stdout.readline(), timeout=15)
            if not line.startswith(b"PDH1 "):
                print("helper did not start streaming — its stderr above explains why")
                await asyncio.sleep(3)
                continue

            parts = line.decode().split()
            _, w, h, fps, codec = parts[:5]
            display_id = int(parts[5]) if len(parts) > 5 else 0
            print(f"virtual display: {w}x{h} @ {fps} fps ({codec})")
            # client-facing greeting (phone protocol); the helper's "PDH1 ..."
            # line is internal between helper and pdctl
            hub.header_line = f"PD01 {w} {h} {fps} {codec}\n".encode()
            # if the phone already picked a frame rate, re-apply it now
            hub.apply_capture_fps()
            started = True
            mode_task = asyncio.create_task(
                _watch_display_mode(proc, display_id, int(w), int(h)))

            first_frame = True
            while True:
                # Software cursor packets arrive at least once per second even
                # on a static screen, so 5 s means the helper is wedged. The
                # first frame gets 15 s for ScreenCaptureKit startup.
                timeout = 15 if first_frame else 5
                hdr = await asyncio.wait_for(
                    proc.stdout.readexactly(FRAME_HDR.size), timeout=timeout)
                length, flags = FRAME_HDR.unpack(hdr)
                payload = await asyncio.wait_for(
                    proc.stdout.readexactly(length), timeout=5)
                first_frame = False
                packet = hdr + payload
                if flags & 0x02:
                    # cursor position packet: forward, never count as video
                    hub.last_cursor = packet
                    await hub.broadcast(packet)
                    continue
                keyframe = bool(flags & 0x01)
                if keyframe:
                    hub.remember_frame(packet, keyframe=True)
                    if not hub.header_ready.is_set():
                        # Open the door only once a keyframe exists: a client
                        # that connected a moment earlier must not get a
                        # greeting with an empty GOP (no picture until the
                        # next screen change).
                        hub.header_ready.set()
                else:
                    hub.remember_frame(packet, keyframe=False)
                await hub.broadcast(packet, keyframe=keyframe)

                frames += 1
                win_frames += 1
                win_bytes += len(packet)
                if win_frames >= 300:          # instantaneous rate per window,
                    now = time.monotonic()     # not a cumulative average
                    dt = now - t0
                    print(f"  {win_frames / dt:6.1f} fps   "
                          f"{win_bytes * 8 / dt / 1e6:6.1f} Mbps   "
                          f"clients={len(hub.clients)}   "
                          f"client_drops={hub.drops - drops_at_last}", flush=True)
                    drops_at_last = hub.drops
                    t0 = now
                    win_frames = 0
                    win_bytes = 0
        except asyncio.IncompleteReadError:
            pass
        except asyncio.TimeoutError:
            print("helper produced no output — killing and restarting it")
        finally:
            watchdog.cancel()
            with contextlib.suppress(Exception, asyncio.CancelledError):
                await watchdog
            if mode_task:
                mode_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await mode_task
            if proc.returncode is None:
                proc.terminate()
                try:
                    await asyncio.wait_for(proc.wait(), timeout=5)
                except (asyncio.TimeoutError, asyncio.CancelledError):
                    with contextlib.suppress(Exception):
                        proc.kill()
                    with contextlib.suppress(Exception, asyncio.CancelledError):
                        await asyncio.wait_for(proc.wait(), timeout=5)
            hub.helper_in = None
            hub.header_ready.clear()

        if hub.idle_stopped:
            hub.idle_stopped = False
            hub.reset_session()
            print("virtual display removed — waiting for the phone", flush=True)
            continue

        if started and proc.returncode == 0:
            if getattr(args, "seconds", 0):
                print("stream ended (helper finished)")
                if frames == 0:
                    print("note: no frames were received — an idle or asleep display produces")
                    print("      no traffic. Drag a window onto PhoneDisplay and it will flow.")
                return 0
            # someone stopped the helper (pkill, macOS, ...) but the server and
            # the phone are still here: bring the display back instead of dying
            hub.reset_session()
            print("helper exited cleanly — restarting it in 3 s", flush=True)
            await asyncio.sleep(3)
            continue

        if not started:
            await asyncio.sleep(3)             # helper failed: try again shortly
            continue

        hub.reset_session()
        print(f"capture stopped (helper exit {proc.returncode}) — restarting in 3 s",
              flush=True)
        await asyncio.sleep(3)


def cmd_stream(args) -> int:
    if not os.path.exists(HELPER):
        sys.exit("vdhelper not built yet — run: python3 pdctl.py build")
    try:
        return asyncio.run(run_stream(args))
    except KeyboardInterrupt:
        print("\nstopped.")
        return 0


# ---------------------------------------------------------------- cli

def main() -> int:
    p = argparse.ArgumentParser(prog="pdctl", description="PhoneDisplay host control")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("build", help="compile the native helper")

    def common(sp):
        sp.add_argument("--width", type=int, default=1920)
        sp.add_argument("--height", type=int, default=1080)
        sp.add_argument("--refresh", type=float, default=60)
        sp.add_argument("--inches", type=float, default=6.5,
                        help="pretend panel diagonal in inches (drives DPI scaling)")
        sp.add_argument("--hidpi", action="store_true")
        sp.add_argument("--name", default="PhoneDisplay")
        sp.add_argument("--seconds", type=int, default=0, help="auto-stop after N seconds")

    d = sub.add_parser("display", help="create a virtual second monitor")
    common(d)

    s = sub.add_parser("stream", help="virtual monitor + capture + TCP server")
    common(s)
    s.add_argument("--fps", type=int, default=60)
    s.add_argument("--bitrate", type=float, default=10.0, help="Mbps")
    s.add_argument("--bind", default="127.0.0.1",
                   help="listen address (default 127.0.0.1; use 0.0.0.0 for Wi-Fi)")
    s.add_argument("--port", type=int, default=8420)
    s.add_argument("--token", default=None,
                   help="shared secret (default: ~/.phonedisplay-token, generated once)")
    s.add_argument("--synthetic", action="store_true",
                   help="stream a test pattern instead of the screen (no display, no permissions)")
    s.add_argument("--no-caffeinate", action="store_true",
                   help="do not keep the Mac awake while streaming")
    s.add_argument("--idle-grace", type=float, default=30.0, metavar="SECONDS",
                   help="remove the virtual display after this long without a "
                        "connected phone (default 30; 0 = immediately)")

    u = sub.add_parser("usb", help="set up the USB tunnel to the phone (adb reverse)")
    u.add_argument("--port", type=int, default=8420)
    u.add_argument("--watch", action="store_true",
                   help="keep watching; re-arm the tunnel whenever the phone (re)appears")

    args = p.parse_args()
    return {"build": cmd_build, "display": cmd_display, "stream": cmd_stream,
            "usb": cmd_usb}[args.cmd](args)


if __name__ == "__main__":
    raise SystemExit(main())
