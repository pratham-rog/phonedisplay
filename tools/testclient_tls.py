#!/usr/bin/env python3
"""Pinned TLS developer client for the PhoneDisplay secure host.

Reads the Mac's 0600 dev-pairing.json, verifies the certificate fingerprint,
pairs once, then connects with the issued device secret and prints stream stats.
The pairing token and device secret are never printed.
"""

from __future__ import annotations

import hashlib
import json
import os
import socket
import ssl
import sys
import time
from pathlib import Path
from urllib.parse import parse_qs, urlparse

PAIRING_FILE = (
    Path.home()
    / "Library"
    / "Application Support"
    / "PhoneDisplay"
    / "dev-pairing.json"
)
DEVICE_FILE = Path(
    os.environ.get(
        "PHONEDISPLAY_TEST_DEVICE",
        str(Path.home() / ".phonedisplay-test-device.json"),
    )
)


class Reader:
    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.buffer = bytearray()

    def _fill(self) -> bool:
        data = self.sock.recv(65536)
        if not data:
            return False
        self.buffer.extend(data)
        return True

    def line(self) -> bytes:
        while b"\n" not in self.buffer:
            if not self._fill():
                raise EOFError("connection closed while reading a line")
        index = self.buffer.index(b"\n")
        line = bytes(self.buffer[:index])
        del self.buffer[: index + 1]
        return line

    def exact(self, count: int) -> bytes:
        while len(self.buffer) < count:
            if not self._fill():
                raise EOFError("connection closed while reading a frame")
        data = bytes(self.buffer[:count])
        del self.buffer[:count]
        return data

    def pending(self) -> bool:
        return bool(self.buffer)


def send_json(sock: socket.socket, value: dict) -> None:
    sock.sendall(json.dumps(value, separators=(",", ":")).encode() + b"\n")


def send_frame(sock: socket.socket, flags: int, payload: bytes) -> None:
    sock.sendall(len(payload).to_bytes(4, "big") + bytes([flags]) + payload)


def connect_pinned(host: str, port: int, fingerprint: str) -> ssl.SSLSocket:
    raw = socket.create_connection((host, port), timeout=8)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    tls = context.wrap_socket(raw, server_hostname=host)
    actual = hashlib.sha256(tls.getpeercert(binary_form=True)).hexdigest()
    if actual != fingerprint:
        tls.close()
        raise ValueError("certificate fingerprint mismatch; refusing to connect")
    return tls


def save_device(host: str, port: int, fingerprint: str, device_id: str, secret: str) -> None:
    data = {
        "host": host,
        "port": port,
        "fingerprint": fingerprint,
        "deviceId": device_id,
        "secret": secret,
    }
    fd = os.open(DEVICE_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(data, handle)
    os.chmod(DEVICE_FILE, 0o600)


def main() -> int:
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 6.0
    device_id = None
    secret = None

    if PAIRING_FILE.exists():
        record = json.loads(PAIRING_FILE.read_text())
        parsed = urlparse(record["url"])
        query = {key: values[0] for key, values in parse_qs(parsed.query).items()}
        host = query["host"]
        port = int(query["port"])
        token = query["token"]
        fingerprint = query["fp"]

        tls = connect_pinned(host, port, fingerprint)
        reader = Reader(tls)
        send_json(tls, {
            "type": "pair",
            "v": 1,
            "token": token,
            "device": {"name": "Python TLS test", "model": "developer"},
        })
        paired = json.loads(reader.line())
        if paired.get("type") != "paired":
            print(f"pairing failed: {paired.get('message', paired.get('type'))}", file=sys.stderr)
            tls.close()
            return 4
        device_id = paired["deviceId"]
        secret = paired["secret"]
        save_device(host, port, fingerprint, device_id, secret)
        tls.close()
        print("paired; reconnecting with the stored device secret")
    elif DEVICE_FILE.exists():
        saved = json.loads(DEVICE_FILE.read_text())
        host = saved["host"]
        port = int(saved["port"])
        fingerprint = saved["fingerprint"]
        device_id = saved["deviceId"]
        secret = saved["secret"]
        print("using stored device secret")
    else:
        print(
            f"missing {PAIRING_FILE} and {DEVICE_FILE}; "
            "start the Mac app with PHONEDISPLAY_DEV=1",
            file=sys.stderr,
        )
        return 2

    tls = connect_pinned(host, port, fingerprint)
    reader = Reader(tls)
    send_json(tls, {
        "type": "hello",
        "v": 1,
        "deviceId": device_id,
        "auth": secret,
        "display": {"width": 1920, "height": 1080, "refresh": 60},
        "decode": {"codecs": ["h264"], "maxWidth": 1920, "maxHeight": 1080},
    })
    stream = json.loads(reader.line())
    if stream.get("type") != "stream":
        print(f"hello failed: {stream.get('message', stream.get('type'))}", file=sys.stderr)
        tls.close()
        return 5
    print(
        "stream: {width}x{height} @ {fps} fps, {codec}, {bitrate} Mbps".format(**stream)
    )

    tls.settimeout(0.2)
    started = time.monotonic()
    deadline = started + seconds
    next_heartbeat = started
    frames = 0
    cursor = 0
    keyframes = 0
    first_frame = None
    while time.monotonic() < deadline:
        if time.monotonic() >= next_heartbeat:
            send_frame(tls, 0x04, b'{"type":"heartbeat"}')
            next_heartbeat = time.monotonic() + 2.0
        try:
            while True:
                header = reader.exact(5)
                length = int.from_bytes(header[:4], "big")
                flags = header[4]
                payload = reader.exact(length)
                if flags & 0x02:
                    cursor += 1
                else:
                    frames += 1
                    if flags & 0x01:
                        keyframes += 1
                    if first_frame is None:
                        first_frame = time.monotonic() - started
                now = time.monotonic()
                if now >= next_heartbeat:
                    send_frame(tls, 0x04, b'{"type":"heartbeat"}')
                    next_heartbeat = now + 2.0
                if now >= deadline:
                    break
        except (socket.timeout, TimeoutError):
            pass
        except EOFError:
            break

    elapsed = time.monotonic() - started
    print(
        f"{frames} video frames in {elapsed:.1f}s "
        f"({frames / max(elapsed, 0.01):.1f} fps, {keyframes} keyframes, "
        f"{cursor} cursor packets)"
    )
    if first_frame is not None:
        print(f"first frame after {first_frame:.2f}s")
    tls.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
