#!/usr/bin/env python3
"""HTTP/1.1 keep-alive benchmark for zhttpd.

A lightweight h2load-style load generator that reuses a single TCP connection
per worker (HTTP/1.1 persistent connections) and reports throughput and
latency. Used to produce the long-connection benchmark numbers in README.md.

Usage:
    python3 tests/bench_keepalive.py [url] [connections] [requests] [threads]

Example:
    python3 tests/bench_keepalive.py http://127.0.0.1:8080/ 100 100000 4
"""

import socket
import sys
import threading
import time
from urllib.parse import urlparse

URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080/"
CONNECTIONS = int(sys.argv[2]) if len(sys.argv) > 2 else 100
REQUESTS = int(sys.argv[3]) if len(sys.argv) > 3 else 100000
THREADS = int(sys.argv[4]) if len(sys.argv) > 4 else 4

parsed = urlparse(URL)
HOST = parsed.hostname or "127.0.0.1"
PORT = parsed.port or 80
PATH = parsed.path or "/"

REQUEST = (
    f"GET {PATH} HTTP/1.1\r\n"
    f"Host: {HOST}:{PORT}\r\n"
    f"User-Agent: zhttpd-bench/1.0\r\n"
    f"Accept: */*\r\n"
    f"Connection: keep-alive\r\n\r\n"
).encode()

lock = threading.Lock()
total_ok = 0
total_err = 0
latencies = []


def read_response(sock):
    """Read one HTTP/1.1 response (headers + body) from a persistent socket."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            raise ConnectionError("closed while reading headers")
        buf += chunk
    header, _, rest = buf.partition(b"\r\n\r\n")
    content_length = 0
    for line in header.split(b"\r\n")[1:]:
        if line.lower().startswith(b"content-length:"):
            content_length = int(line.split(b":", 1)[1].strip())
            break
    body = rest
    while len(body) < content_length:
        chunk = sock.recv(65536)
        if not chunk:
            raise ConnectionError("closed while reading body")
        body += chunk
    return header


def worker(n_conns, n_reqs):
    global total_ok, total_err
    per_conn = n_reqs // n_conns
    ok = 0
    err = 0
    local_lat = []
    for _ in range(n_conns):
        try:
            sock = socket.create_connection((HOST, PORT), timeout=10)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            err += per_conn
            continue
        try:
            for _ in range(per_conn):
                t0 = time.perf_counter()
                sock.sendall(REQUEST)
                read_response(sock)
                local_lat.append(time.perf_counter() - t0)
                ok += 1
        except (OSError, ConnectionError):
            err += 1
        finally:
            sock.close()
    with lock:
        total_ok += ok
        total_err += err
        latencies.extend(local_lat)


def main():
    print(f"Benchmarking {URL}")
    print(f"  connections={CONNECTIONS} requests={REQUESTS} threads={THREADS}")
    conns_per_thread = max(1, CONNECTIONS // THREADS)
    threads = []
    start = time.perf_counter()
    for _ in range(THREADS):
        t = threading.Thread(target=worker, args=(conns_per_thread, REQUESTS // THREADS))
        t.start()
        threads.append(t)
    for t in threads:
        t.join()
    elapsed = time.perf_counter() - start

    rps = total_ok / elapsed if elapsed > 0 else 0
    latencies.sort()
    avg = sum(latencies) / len(latencies) * 1000 if latencies else 0
    p50 = latencies[len(latencies) // 2] * 1000 if latencies else 0
    p99 = latencies[int(len(latencies) * 0.99)] * 1000 if latencies else 0

    print()
    print(f"  finished in {elapsed:.2f}s")
    print(f"  successful requests: {total_ok}")
    print(f"  failed requests:     {total_err}")
    print(f"  requests/sec:        {rps:.2f}")
    print(f"  latency avg:         {avg:.3f} ms")
    print(f"  latency p50:         {p50:.3f} ms")
    print(f"  latency p99:         {p99:.3f} ms")


if __name__ == "__main__":
    main()
