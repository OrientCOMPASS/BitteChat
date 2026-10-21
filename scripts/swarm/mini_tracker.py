#!/usr/bin/env python3
"""Tiny BEP-3 HTTP tracker for the dual-instance emulator swarm.

The CI host seeds scripts/swarm/gen_torrent.py's torrent with aria2; the
emulator's libtorrent instance announces here through 10.0.2.2 (qemu's alias
for the host loopback) and is handed the seeder's endpoint, which is the only
peer it is ever told about. The seeder itself announces from the host, where
the same address would point at itself, so requests are told apart by
User-Agent: aria2 gets an empty peer list, libtorrent gets the seed.

Usage: mini_tracker.py --port 6969 --seed-ip 10.0.2.2 --seed-port 6881
"""

import argparse
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

SEED_IP = "10.0.2.2"
SEED_PORT = 6881
SEED_PEER_ID = b"-BC0001-swarmseed"  # padded to 20 bytes below
SEED_PEER_ID = (SEED_PEER_ID + b"\0" * 20)[:20]

_seen = {}  # infohash (hex) -> {"complete": n, "incomplete": n}


def bencode(obj):
    if isinstance(obj, int):
        return b"i" + str(obj).encode() + b"e"
    if isinstance(obj, bytes):
        return str(len(obj)).encode() + b":" + obj
    if isinstance(obj, str):
        b = obj.encode()
        return str(len(b)).encode() + b":" + b
    if isinstance(obj, (list, tuple)):
        return b"l" + b"".join(bencode(e) for e in obj) + b"e"
    if isinstance(obj, dict):
        out = b"d"
        for k in sorted(obj):
            out += bencode(k) + bencode(obj[k])
        return out + b"e"
    raise TypeError(type(obj))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "BitteSwarmTracker/1"

    def log_message(self, fmt, *args):  # keep stderr quiet; we log ourselves
        pass

    def _send(self, payload):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        url = urlparse(self.path)
        # info_hash arrives as raw percent-escaped bytes: keep them byte-exact
        qs = parse_qs(url.query, keep_blank_values=True, encoding="latin-1")
        ua = self.headers.get("User-Agent", "")
        if url.path == "/announce":
            self._announce(qs, ua)
        elif url.path == "/scrape":
            self._scrape(qs)
        elif url.path == "/ping":
            sys.stderr.write("%.0f ping ua=%r\n" % (time.time(), ua))
            sys.stderr.flush()
            self._send(b"pong")
        else:
            sys.stderr.write("%.0f get %s ua=%r\n" % (time.time(), url.path, ua))
            sys.stderr.flush()
            self.send_error(404)

    def _announce(self, qs, ua):
        raw = qs.get("info_hash", [b""])[0]
        ih = raw.encode("latin-1") if isinstance(raw, str) else raw
        ih_hex = ih.hex()
        port = int(qs.get("port", ["0"])[0] or 0)
        left = int(qs.get("left", ["0"])[0] or 0)
        ent = _seen.setdefault(ih_hex, {"complete": 0, "incomplete": 0})
        if left == 0:
            ent["complete"] = max(ent["complete"], 1)
        else:
            ent["incomplete"] = max(ent["incomplete"], 1)
        is_seed_ua = ua.lower().startswith("aria2")
        peers = []
        if not is_seed_ua:
            peers.append(
                {
                    "ip": SEED_IP,
                    "peer id": SEED_PEER_ID,
                    "port": SEED_PORT,
                }
            )
        resp = bencode(
            {
                "complete": ent["complete"],
                "incomplete": ent["incomplete"],
                "interval": 15,
                "min interval": 5,
                "peers": peers,
            }
        )
        sys.stderr.write(
            "%.0f announce ih=%s ua=%r port=%d left=%d peers=%d\n"
            % (time.time(), ih_hex, ua, port, left, len(peers))
        )
        sys.stderr.flush()
        self._send(resp)

    def _scrape(self, qs):
        files = {}
        wanted = [
            v.encode("latin-1").hex() for v in qs.get("info_hash", [])
        ]
        for ih_hex, ent in _seen.items():
            if wanted and ih_hex not in wanted:
                continue
            # BEP-3: files dict is keyed by the RAW 20-byte infohash
            files[bytes.fromhex(ih_hex)] = {
                "complete": ent["complete"],
                "downloaded": ent["complete"] + ent["incomplete"],
                "incomplete": ent["incomplete"],
            }
        self._send(bencode({"files": files}))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=6969)
    ap.add_argument("--seed-ip", default="10.0.2.2")
    ap.add_argument("--seed-port", type=int, default=6881)
    args = ap.parse_args()
    global SEED_IP, SEED_PORT
    SEED_IP = args.seed_ip
    SEED_PORT = args.seed_port
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    sys.stderr.write("mini tracker on 127.0.0.1:%d seed=%s:%d\n"
                     % (args.port, SEED_IP, SEED_PORT))
    sys.stderr.flush()
    srv.serve_forever()


if __name__ == "__main__":
    main()
