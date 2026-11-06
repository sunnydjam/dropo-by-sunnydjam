"""Offline regression: a stalled TLS peer must not multiply XHTTP carriers.

Only ephemeral loopback sockets and a synthetic VLESS identity are used. No TUN,
system routes, production endpoints, privileges, or client profiles are touched.
"""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import socket
import struct
import subprocess
import threading
import time


def verify(runtime, digest):
    if hashlib.sha256(runtime.read_bytes()).hexdigest() != digest:
        raise RuntimeError("Runtime checksum mismatch")
    peer = socket.socket()
    peer.bind(("127.0.0.1", 0))
    peer.listen(32)
    peer.settimeout(0.1)
    reservation = socket.socket()
    reservation.bind(("127.0.0.1", 0))
    socks_port = reservation.getsockname()[1]
    accepted = []
    stop = threading.Event()

    def blackhole():
        while not stop.is_set():
            try:
                connection, _ = peer.accept()
                accepted.append(connection)
            except socket.timeout:
                pass

    server = threading.Thread(target=blackhole, daemon=True)
    server.start()
    config = {
        "log": {"loglevel": "none"},
        "inbounds": [{"listen": "127.0.0.1", "port": socks_port,
                      "protocol": "socks", "settings": {"auth": "noauth"}}],
        "outbounds": [{"protocol": "vless", "settings": {"vnext": [{
            "address": "127.0.0.1", "port": peer.getsockname()[1],
            "users": [{"id": "11111111-1111-4111-8111-111111111111",
                       "encryption": "none"}]}]},
            "streamSettings": {"network": "xhttp", "security": "tls",
                               "tlsSettings": {"serverName": "localhost", "alpn": ["h2"]},
                               "xhttpSettings": {"mode": "packet-up", "path": "/fixture",
                                                 "xmux": {"maxConnections": 1,
                                                          "maxConcurrency": 0}}}}],
    }
    process = None
    try:
        reservation.close()
        process = subprocess.Popen([str(runtime), "run", "-config", "stdin:"],
                                   stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL,
                                   creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        process.stdin.write(json.dumps(config).encode())
        process.stdin.close()
        deadline = time.monotonic() + 5
        while True:
            if process.poll() is not None:
                raise RuntimeError("Fixture core exited")
            try:
                with socket.create_connection(("127.0.0.1", socks_port), timeout=0.2):
                    break
            except OSError:
                if time.monotonic() > deadline:
                    raise RuntimeError("Fixture listener not ready")
                time.sleep(0.05)

        gate = threading.Barrier(12)

        def request(_):
            with socket.create_connection(("127.0.0.1", socks_port), timeout=4) as connection:
                connection.sendall(b"\x05\x01\x00")
                if connection.recv(2) != b"\x05\x00":
                    raise RuntimeError("SOCKS negotiation failed")
                gate.wait(timeout=4)
                name = b"example.com"
                connection.sendall(b"\x05\x01\x00\x03" + bytes([len(name)]) + name + struct.pack("!H", 80))
                reply = connection.recv(10)
                if len(reply) < 2 or reply[1] != 0:
                    raise RuntimeError("SOCKS connection refused")
                connection.sendall(b"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
                try:
                    connection.recv(1)
                except socket.timeout:
                    pass  # The peer deliberately never completes TLS.

        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as executor:
            list(executor.map(request, range(12)))
        result = {"sessions": 12, "physicalCarriers": len(accepted),
                  "budget": 1, "loopbackOnly": True,
                  "passed": len(accepted) == 1}
        print(json.dumps(result))
        return result["passed"]
    finally:
        reservation.close()
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        stop.set()
        server.join(timeout=1)
        peer.close()
        for connection in accepted:
            connection.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--sha256", required=True)
    args = parser.parse_args()
    raise SystemExit(0 if verify(args.runtime.resolve(strict=True), args.sha256) else 1)
