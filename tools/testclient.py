#!/usr/bin/env python3
"""
Minimal PhoneDisplay protocol test client.

This is exactly what the Android app will do, in Python:
connect → send "PD01 <token>\\n" → read header line → read frames.

Usage: python3 testclient.py <host> [port] [seconds] [token]
The token defaults to ~/.phonedisplay-token.
"""
import os
import socket
import struct
import sys
import time

FRAME_HDR = struct.Struct(">IB")
TOKEN_FILE = os.path.expanduser("~/.phonedisplay-token")


def main() -> None:
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8420
    secs = float(sys.argv[3]) if len(sys.argv) > 3 else 5.0
    try:
        token = sys.argv[4] if len(sys.argv) > 4 else open(TOKEN_FILE, encoding="ascii").read().strip()
    except OSError:
        sys.exit(f"no token: start pdctl stream once to create {TOKEN_FILE}")
    if not token:
        sys.exit(f"empty token file {TOKEN_FILE}")

    s = socket.create_connection((host, port), timeout=5)
    s.sendall(f"PD01 {token}\n".encode("ascii"))
    f = s.makefile("rb")

    hello = f.readline().decode().strip()
    print("server says:", hello)
    if not hello.startswith("PD01 "):
        sys.exit("unexpected greeting")
    w, h, fps, codec = hello.split()[1:]
    print(f"stream: {w}x{h} @ {fps} fps, {codec}")

    t0 = time.time()
    frames = keys = cursors = total = 0
    first_frame_at = None
    while time.time() - t0 < secs:
        hdr = f.read(FRAME_HDR.size)
        if len(hdr) < FRAME_HDR.size:
            print("connection closed by server")
            break
        length, flags = FRAME_HDR.unpack(hdr)
        data = f.read(length)
        if len(data) < length:
            print("truncated frame")
            break
        if flags & 0x02:          # cursor position packet, not video
            cursors += 1
            continue
        frames += 1
        total += FRAME_HDR.size + length
        if flags & 0x01:
            keys += 1
        if first_frame_at is None:
            first_frame_at = time.time() - t0

    dt = time.time() - t0
    print(f"\n{frames} frames in {dt:.1f}s  "
          f"({frames / dt:.1f} fps, {keys} keyframes, "
          f"{total * 8 / dt / 1e6:.1f} Mbps)")
    print(f"{cursors} cursor packets in {dt:.1f}s ({cursors / dt:.1f}/s)")
    if first_frame_at is not None:
        print(f"first frame after {first_frame_at:.2f}s (leave latency)")


if __name__ == "__main__":
    main()
