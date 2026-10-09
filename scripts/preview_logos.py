#!/usr/bin/env python3
"""Assemble an inspection sheet from existing logos. Never generates or edits logo artwork.

Requires the system ffmpeg executable; all Python imports are standard library.
Rows: 160px on light, 64px on light, 64px on dark, 32px circles on light and dark.
Columns: options 1 through 5, in order.
"""

from pathlib import Path
import subprocess
import zlib
import struct

ROOT = Path(__file__).resolve().parents[1]
WIDTH, HEIGHT = 960, 488
LIGHT, DARK = (247, 247, 244), (16, 19, 27)
canvas = bytearray(WIDTH * HEIGHT * 3)


def fill(x, y, width, height, color):
    line = bytes(color) * width
    for row in range(y, y + height):
        start = (row * WIDTH + x) * 3
        canvas[start : start + len(line)] = line


def put(path, x, y, size, circle=False):
    pixels = subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(path),
        "-vf", f"scale={size}:{size}:flags=lanczos", "-frames:v", "1",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
    ], check=True, capture_output=True).stdout
    assert len(pixels) == size * size * 3
    for row in range(size):
        for col in range(size):
            if circle and (col + 0.5 - size / 2) ** 2 + (row + 0.5 - size / 2) ** 2 > (size / 2) ** 2:
                continue
            source = (row * size + col) * 3
            target = ((y + row) * WIDTH + x + col) * 3
            canvas[target : target + 3] = pixels[source : source + 3]


def chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)


fill(0, 0, WIDTH, HEIGHT, LIGHT)
fill(0, 288, WIDTH, 100, DARK)
for option in range(1, 6):
    x = (option - 1) * 192
    path = ROOT / f"logos/logo-{option}.png"
    put(path, x + 16, 16, 160)
    put(path, x + 64, 208, 64)
    put(path, x + 64, 306, 64)
    fill(x + 96, 388, 96, 100, DARK)
    put(path, x + 32, 422, 32, circle=True)
    put(path, x + 128, 422, 32, circle=True)

scanlines = b"".join(b"\0" + canvas[row * WIDTH * 3 : (row + 1) * WIDTH * 3] for row in range(HEIGHT))
output = ROOT / "artifacts/size-check.png"
output.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0))
                   + chunk(b"IDAT", zlib.compress(scanlines, 9)) + chunk(b"IEND", b""))
print(output.relative_to(ROOT))
