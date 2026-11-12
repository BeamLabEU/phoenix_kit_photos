"""Shared by the fake yt-dlp and gallery-dl the fetch tests run instead of the real ones.

They print what the real tools print (the JSON of a look, the marker lines a fetch asks
for) and make real files, so the whole path runs without the network. FAKE_MODE picks
what happens; FAKE_LOG, when set, gets each argv as one JSON line."""
import json, os, struct, sys, zlib


def log_args():
    path = os.environ.get("FAKE_LOG")
    if path:
        with open(path, "a") as f:
            f.write(json.dumps(sys.argv[1:]) + "\n")


def arg_after(flag):
    args = sys.argv[1:]
    for i, a in enumerate(args):
        if a == flag and i + 1 < len(args):
            return args[i + 1]
    return None


def png(path, seed):
    """A 2x2 PNG whose colour depends on seed, so each file has its own bytes."""
    r, g, b = (seed * 70) % 256, (seed * 130) % 256, (seed * 200) % 256
    raw = b"".join(b"\x00" + bytes([r, g, b]) * 2 for _ in range(2))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(data)


def err(text):
    sys.stderr.write(text + "\n")
    sys.stderr.flush()
