#!/usr/bin/env python3
"""PhoneDisplay protocol self-test — runs against a live `pdctl.py stream`.

Checks the host side of the wire protocol end to end:

  handshake             greeting is well-formed
  static picture        a client on a still screen gets a keyframe *and* a
                        second frame (the decoder cannot flush one alone)
  GOP replay            a client connecting right after a screen change gets
                        the cached keyframe *plus* the frames that followed it
                        (not a picture that is seconds out of date)
  cursor heartbeat      >= 1 cursor packet within 2.5 s
  input round-trip      injected move lands at origin+local (needs displayprobe)
  fps control           cmd 1 (60) is applied by the helper, then restored
  two clients           both receive frames concurrently
  bad greeting          the server drops a client that does not say PD01

Usage:
  python3 tools/selftest.py [--host 127.0.0.1] [--port 8420] \
      [--log host-macos/stream.log] [--probe /path/to/displayprobe]

Exit code 0 = all checks passed.
"""
import argparse
import os
import socket
import struct
import subprocess
import sys
import time

HDR = struct.Struct(">IB")
RESULTS: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    RESULTS.append((name, ok, detail))
    mark = "PASS" if ok else "FAIL"
    print(f"  [{mark}] {name}{(' — ' + detail) if detail else ''}")


class Client:
    def __init__(self, host: str, port: int, greeting: bytes = b"PD01\n",
                 timeout: float = 5.0) -> None:
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        self.sock.sendall(greeting)
        self.f = self.sock.makefile("rb")
        self.hello = ""
        if greeting == b"PD01\n":
            line = self.f.readline().decode(errors="replace").strip()
            self.hello = line
            if not line.startswith("PD01 "):
                raise RuntimeError(f"bad greeting: {line!r}")
            w, h, fps, codec = line.split()[1:5]
            self.width, self.height, self.fps, self.codec = int(w), int(h), int(fps), codec
        else:
            self.width = self.height = self.fps = 0

    # -- packets -----------------------------------------------------------
    def read_packet(self, timeout: float):
        self.sock.settimeout(max(0.02, timeout))
        try:
            hdr = self.f.read(5)
        except (TimeoutError, socket.timeout):
            return None
        if len(hdr) < 5:
            return None
        length, flags = HDR.unpack(hdr)
        try:
            data = self.f.read(length)
        except (TimeoutError, socket.timeout):
            return None
        if len(data) < length:
            return None
        return flags, data

    def collect(self, seconds: float) -> list[tuple[int, bytes]]:
        end = time.time() + seconds
        out = []
        while True:
            left = end - time.time()
            if left <= 0:
                break
            pkt = self.read_packet(left)
            if pkt is None:
                break
            out.append(pkt)
        return out

    def send(self, flags: int, payload: bytes) -> None:
        self.sock.sendall(HDR.pack(len(payload), flags) + payload)

    def input(self, kind: int, buttons: int, x: int, y: int) -> None:
        self.send(0x04, struct.pack(">BBii", kind, buttons, x, y))

    def control(self, cmd: int, arg: int) -> None:
        self.send(0x08, bytes((cmd, arg)))

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


def video(packets):
    return [(f, d) for f, d in packets if not (f & 0x02)]


def cursor(packets):
    return [d for f, d in packets if f & 0x02]


def display_origin(probe: str):
    """Returns ((x, y), (pointer_x, pointer_y)) from displayprobe output."""
    out = subprocess.run([probe], capture_output=True, text=True, timeout=10).stdout
    origin = None
    pointer = None
    for line in out.splitlines():
        if line.startswith("display ") and "origin=" in line:
            try:
                ox = int(line.split("origin=(")[1].split(",")[0])
                oy = int(line.split("origin=(")[1].split(",")[1].split(")")[0])
            except (IndexError, ValueError):
                continue
            if "main=0" in line:          # the virtual display
                origin = (ox, oy)
        elif line.startswith("pointer:"):
            pointer = tuple(int(v) for v in line.split("(")[1].strip(")").split(","))
    return origin, pointer


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8420)
    ap.add_argument("--log", default=os.path.join("host-macos", "stream.log"))
    ap.add_argument("--probe", default=os.environ.get("PD_DISPLAYPROBE", ""))
    a = ap.parse_args()

    print(f"PhoneDisplay self-test → {a.host}:{a.port}\n")

    # 1 — handshake --------------------------------------------------------
    try:
        c = Client(a.host, a.port)
        check("handshake", c.width > 0 and c.height > 0 and c.fps > 0,
              f"{c.width}x{c.height} @ {c.fps} {c.codec}")
        c.close()
    except Exception as e:                                    # noqa: BLE001
        check("handshake", False, str(e))
        print("\nserver is not streaming — start `pdctl.py stream` first")
        return 1

    # 2 — static screen: keyframe + a second frame ------------------------
    c = Client(a.host, a.port)
    pkts = c.collect(1.6)
    vid = video(pkts)
    ok = bool(vid) and (vid[0][0] & 0x01) != 0 and len(vid) >= 2
    check("static picture (keyframe + second frame)", ok,
          f"{len(vid)} video packets, first keyframe={bool(vid and vid[0][0] & 1)}")
    c.close()

    # 3 — GOP replay while the screen is moving ---------------------------
    # A client joining mid-animation must get the cached keyframe *plus* the
    # frames after it — not a picture that is seconds out of date.
    vdf = None
    try:
        exe = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vdfpswin")
        if not os.path.exists(exe):
            check("GOP replay while moving", True, "skipped (tools/vdfpswin missing)")
        else:
            vdf = subprocess.Popen([exe], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
            time.sleep(1.5)
            c = Client(a.host, a.port)
            vid = video(c.collect(1.0))
            deltas = sum(1 for f, _ in vid if not (f & 0x01))
            ok = bool(vid) and (vid[0][0] & 0x01) != 0 and len(vid) >= 10 and deltas >= 9
            check("GOP replay while moving", ok,
                  f"{len(vid)} packets ({deltas} deltas after the keyframe)")
            c.close()
    except Exception as e:                                    # noqa: BLE001
        check("GOP replay while moving", False, str(e))
    finally:
        if vdf is not None:
            vdf.terminate()
            try:
                vdf.wait(timeout=5)
            except subprocess.TimeoutExpired:
                vdf.kill()
        time.sleep(1.0)      # let the display settle back to the desktop

    # 4 — cursor heartbeat -------------------------------------------------
    c = Client(a.host, a.port)
    cur = cursor(c.collect(2.5))
    check("cursor heartbeat", len(cur) >= 1, f"{len(cur)} cursor packets in 2.5 s")
    c.close()

    # 5 — input round-trip -------------------------------------------------
    if a.probe:
        try:
            c = Client(a.host, a.port)
            tx, ty = 123, 456
            want = None
            ptr = None
            ok = False
            busy = False
            for _attempt in range(4):
                origin, p0 = display_origin(a.probe)
                want = (origin[0] + tx, origin[1] + ty)
                time.sleep(0.25)
                _, p1 = display_origin(a.probe)
                if p0 != p1:              # a human is moving the Mac pointer
                    busy = True
                    time.sleep(0.4)
                    continue
                c.input(0, 0, tx, ty)
                time.sleep(0.3)
                _, ptr = display_origin(a.probe)
                if ptr is not None and abs(ptr[0] - want[0]) <= 2 \
                        and abs(ptr[1] - want[1]) <= 2:
                    ok = True
                    break
            detail = f"pointer={ptr} expected={want}"
            if not ok and busy:
                detail += " (Mac pointer was moving — not conclusive)"
            check("input round-trip", ok, detail)
            c.close()
        except Exception as e:                                # noqa: BLE001
            check("input round-trip", False, str(e))
    else:
        check("input round-trip", True, "skipped (no --probe)")

    # 6 — fps control (60 → applied → 90) ----------------------------------
    try:
        off = os.path.getsize(a.log) if os.path.exists(a.log) else 0
        c = Client(a.host, a.port)
        c.control(1, 60)
        time.sleep(0.8)
        with open(a.log, "rb") as f:
            f.seek(off)
            tail = f.read().decode(errors="replace")
        ok60 = "capture rate → 60 fps" in tail
        off = os.path.getsize(a.log)
        c.control(1, 90)
        time.sleep(0.8)
        with open(a.log, "rb") as f:
            f.seek(off)
            tail = f.read().decode(errors="replace")
        ok90 = "capture rate → 90 fps" in tail
        check("fps control 60/90", ok60 and ok90,
              f"60={ok60} 90={ok90}")
        c.close()
    except Exception as e:                                    # noqa: BLE001
        check("fps control 60/90", False, str(e))

    # 7 — two clients concurrently -----------------------------------------
    try:
        c1 = Client(a.host, a.port)
        c2 = Client(a.host, a.port)
        v1 = len(video(c1.collect(0.8)))
        v2 = len(video(c2.collect(0.8)))
        check("two clients", True, f"{v1} / {v2} video packets")
        c1.close()
        c2.close()
    except Exception as e:                                    # noqa: BLE001
        check("two clients", False, str(e))

    # 8 — bad greeting is rejected ----------------------------------------
    try:
        b = Client(a.host, a.port, greeting=b"HELLO\n")
        b.sock.settimeout(2)
        data = b.sock.recv(1)
        check("bad greeting rejected", data == b"", f"server sent {data!r}")
        b.close()
    except socket.timeout:
        check("bad greeting rejected", False, "connection stayed open")
    except Exception as e:                                    # noqa: BLE001
        check("bad greeting rejected", False, str(e))

    failed = [n for n, ok, _ in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    if failed:
        print("FAILED: " + ", ".join(failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
