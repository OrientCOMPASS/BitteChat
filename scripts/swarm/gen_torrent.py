#!/usr/bin/env python3
"""Generate the deterministic dual-instance swarm torrent.

The emulator integration test (app/integration_test/bt_view_test.dart) embeds
this exact .torrent (base64) and downloads it from a REAL second BitTorrent
client (aria2) that the CI host seeds behind scripts/swarm/mini_tracker.py on
10.0.2.2 (the emulator's alias for the host loopback). Everything here is
byte-deterministic -- fixed content, fixed piece length, no creation date --
so the infohash is a compile-time constant the Dart test can assert against.

Usage: gen_torrent.py --out DIR
  writes DIR/swarm.torrent and DIR/data/bitte-swarm.bin
"""

import argparse
import hashlib
import os
import random
import sys

NAME = "bitte-swarm.bin"
PIECE_LEN = 262144  # 256 KiB
TOTAL_LEN = 16 * 1024 * 1024  # 16 MiB => 64 pieces
SEED = 0x817E

# sha1(info dict) of the torrent this script produces; guards against any
# accidental non-determinism breaking the constant embedded in the Dart test.
EXPECTED_INFOHASH = "71a6e141ca08eadbe408d70ed97e21562be14fa4"


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


def content_bytes():
    rnd = random.Random(SEED)
    buf = bytearray()
    chunk = 1 << 20
    while len(buf) < TOTAL_LEN:
        buf += rnd.randbytes(chunk)
    return bytes(buf[:TOTAL_LEN])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    data = content_bytes()
    pieces = b"".join(
        hashlib.sha1(data[i:i + PIECE_LEN]).digest()
        for i in range(0, len(data), PIECE_LEN)
    )
    info = {
        "length": len(data),
        "name": NAME,
        "piece length": PIECE_LEN,
        "pieces": pieces,
    }
    torrent = bencode({"info": info})
    infohash = hashlib.sha1(bencode(info)).hexdigest()
    if infohash != EXPECTED_INFOHASH:
        sys.exit(
            "swarm torrent is not deterministic: got %s want %s"
            % (infohash, EXPECTED_INFOHASH)
        )

    datadir = os.path.join(args.out, "data")
    os.makedirs(datadir, exist_ok=True)
    with open(os.path.join(args.out, "swarm.torrent"), "wb") as f:
        f.write(torrent)
    with open(os.path.join(datadir, NAME), "wb") as f:
        f.write(data)
    print(infohash)


if __name__ == "__main__":
    main()
