#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Dump raw 576-byte frames from the board into a .bin file so the web UI can be
validated without Web Serial (open index.html?replay=<file>).

    python tools/dump_frames.py COM13 8 out.bin

Each frame is written back-to-back, exactly as it arrives on the wire.
"""
import sys
import time

import serial


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "COM13"
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 8.0
    out = sys.argv[3] if len(sys.argv) > 3 else "frames.bin"

    ser = serial.Serial(port, 115200, timeout=0.05)
    buf = bytearray()
    t0 = time.time()
    while time.time() - t0 < secs:
        chunk = ser.read(8192)
        if chunk:
            buf.extend(chunk)
    ser.close()

    # align to first magic, then keep whole frames
    start = buf.find(b"\xA5\x5A")
    if start < 0:
        print("no frame found")
        return 1
    body = buf[start:]
    n = len(body) // 576
    with open(out, "wb") as f:
        f.write(body[:n * 576])
    print("%s: %d frames, %d bytes (dropped %d leading + %d trailing)"
          % (out, n, n * 576, start, len(body) - n * 576))
    return 0


if __name__ == "__main__":
    sys.exit(main())
