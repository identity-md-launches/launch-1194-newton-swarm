#!/usr/bin/env python3
"""Offline PNG integrity checks; Python standard library only. Does not draw logos."""

import hashlib
import json
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
PATHS = [f"logos/logo-{i}.png" for i in range(1, 6)] + ["artifacts/logo.png"]


def check(relative):
    data = (ROOT / relative).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{relative}: not PNG"
    offset, kinds, compressed = 8, [], bytearray()
    width = height = None
    while offset < len(data):
        assert len(data) - offset >= 12, f"{relative}: truncated chunk"
        size = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4 : offset + 8]
        end = offset + 12 + size
        assert end <= len(data), f"{relative}: truncated {kind!r}"
        payload = data[offset + 8 : end - 4]
        expected_crc = struct.unpack_from(">I", data, end - 4)[0]
        assert zlib.crc32(kind + payload) & 0xFFFFFFFF == expected_crc, f"{relative}: bad CRC"
        kinds.append(kind)
        if kind == b"IHDR":
            assert len(kinds) == 1 and size == 13, f"{relative}: invalid header"
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            assert (width, height) == (1024, 1024), f"{relative}: wrong dimensions"
            assert (depth, color, compression, filtering, interlace) == (8, 2, 0, 0, 0), (
                f"{relative}: expected opaque, non-interlaced 8-bit RGB"
            )
        if kind == b"IDAT":
            compressed.extend(payload)
        if kind == b"IEND":
            assert size == 0 and end == len(data), f"{relative}: trailing data"
        assert kind not in (b"tRNS", b"acTL", b"fcTL", b"fdAT"), f"{relative}: transparency or animation"
        offset = end
    assert kinds[0] == b"IHDR" and kinds[-1] == b"IEND", f"{relative}: incomplete PNG"
    assert kinds.count(b"IHDR") == kinds.count(b"IEND") == 1, f"{relative}: duplicate header/end"
    assert b"IDAT" in kinds, f"{relative}: no pixels"
    decoder = zlib.decompressobj()
    pixels = decoder.decompress(compressed) + decoder.flush()
    assert decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail, f"{relative}: bad zlib stream"
    stride = width * 3 + 1
    assert len(pixels) == stride * height, f"{relative}: incomplete scanlines"
    assert all(pixels[row * stride] <= 4 for row in range(height)), f"{relative}: bad PNG filter"
    return {"path": relative, "width": width, "height": height, "opaque": True,
            "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


if __name__ == "__main__":
    results = [check(path) for path in PATHS]
    assert len({entry["sha256"] for entry in results[:5]}) == 5, "Options must be different images"
    assert results[5]["sha256"] == results[1]["sha256"], "Primary must match option 2"
    print(json.dumps({"valid": True, "images": results}, indent=2))
