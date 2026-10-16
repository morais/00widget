#!/usr/bin/env python3
"""Capture what the device is showing, as a PNG, over its USB serial port.

    python3 tools/screenshot.py /dev/cu.usbmodem* shot.png [keys]

`keys` are sent first, one character per screen change: n/p next/previous
card, a/A select/run action, r refresh. Standard library and pyserial only
(pyserial ships with PlatformIO: `~/.platformio/penv/bin/python`).
"""

import base64
import struct
import sys
import time
import zlib

import serial


def png(width, height, rgb):
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    rows = b"".join(b"\x00" + rgb[y * width * 3:(y + 1) * width * 3] for y in range(height))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 9))
            + chunk(b"IEND", b""))


def main():
    port, out = sys.argv[1], sys.argv[2]
    keys = sys.argv[3] if len(sys.argv) > 3 else ""
    with serial.Serial(port, 115200, timeout=10) as s:
        for k in keys:
            s.write(k.encode())
            time.sleep(0.4)
        s.reset_input_buffer()
        s.write(b"s")
        while True:
            line = s.readline()
            if not line:
                sys.exit("no screenshot received")
            if line.startswith(b"ZWSHOT"):
                width, height = map(int, line.split()[1:3])
                break
        data = b""
        while not data.endswith(b"ZWEND"):
            more = s.readline()
            if not more:
                sys.exit("screenshot truncated")
            data += more.strip()
        raw = base64.b64decode(data[:-len(b"ZWEND")])

    # The sprite stores RGB565 big-endian.
    rgb = bytearray()
    for (v,) in struct.iter_unpack(">H", raw[:width * height * 2]):
        r, g, b = (v >> 11) & 31, (v >> 5) & 63, v & 31
        rgb += bytes(((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)))
    with open(out, "wb") as f:
        f.write(png(width, height, bytes(rgb)))
    print(out)


if __name__ == "__main__":
    main()
