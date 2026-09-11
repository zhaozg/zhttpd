#!/usr/bin/env python3
"""WebSocket integration test for zhttpd.

Performs a real WebSocket handshake against the running server, verifies the
101 Switching Protocols response, the welcome frame, and an echo round-trip
handled by examples/lua/websocket.lua.

Usage: python3 tests/ws_test.py [host] [port] [path]
Exit code 0 on success, non-zero on failure.
"""

import base64
import json
import os
import socket
import struct
import sys

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8080
PATH = sys.argv[3] if len(sys.argv) > 3 else "/ws"


def fail(msg):
    print(f"FAILED: {msg}")
    sys.exit(1)


def ws_connect(host, port, path):
    s = socket.create_connection((host, port), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n\r\n"
    )
    s.sendall(req.encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = s.recv(4096)
        if not chunk:
            fail("connection closed during handshake")
        resp += chunk
    header, _, rest = resp.partition(b"\r\n\r\n")
    status = header.split(b"\r\n")[0].decode()
    if "101" not in status:
        fail(f"expected 101 Switching Protocols, got: {status}")
    return s, rest


def ws_send(s, data):
    payload = data.encode()
    mask = os.urandom(4)
    frame = bytearray([0x81])
    ln = len(payload)
    if ln < 126:
        frame.append(0x80 | ln)
    elif ln < 65536:
        frame.append(0x80 | 126)
        frame += struct.pack(">H", ln)
    else:
        frame.append(0x80 | 127)
        frame += struct.pack(">Q", ln)
    frame += mask
    frame += bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    s.sendall(frame)


def ws_recv(s, initial=b""):
    buf = bytearray(initial)

    def need(n):
        while len(buf) < n:
            chunk = s.recv(4096)
            if not chunk:
                fail("connection closed while reading frame")
            buf.extend(chunk)

    need(2)
    ln = buf[1] & 0x7F
    offset = 2
    if ln == 126:
        need(4)
        ln = struct.unpack(">H", bytes(buf[2:4]))[0]
        offset = 4
    elif ln == 127:
        need(10)
        ln = struct.unpack(">Q", bytes(buf[2:10]))[0]
        offset = 10
    need(offset + ln)
    payload = bytes(buf[offset : offset + ln])
    return payload.decode(errors="replace")


def main():
    s, rest = ws_connect(HOST, PORT, PATH)
    print("  handshake: 101 Switching Protocols")

    welcome = ws_recv(s, rest)
    try:
        w = json.loads(welcome)
    except json.JSONDecodeError:
        fail(f"welcome frame is not JSON: {welcome!r}")
    if w.get("type") != "connected":
        fail(f"unexpected welcome type: {w}")
    print(f"  welcome: {welcome}")

    ws_send(s, json.dumps({"type": "hello", "msg": "test"}))
    echo = ws_recv(s)
    try:
        e = json.loads(echo)
    except json.JSONDecodeError:
        fail(f"echo frame is not JSON: {echo!r}")
    if e.get("type") != "message" or not e.get("echo"):
        fail(f"unexpected echo response: {e}")
    print(f"  echo: {echo}")

    s.close()
    print("PASSED")


if __name__ == "__main__":
    main()
