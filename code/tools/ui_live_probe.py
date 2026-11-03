#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Full field dump of the 576-byte UI frame, for live bring-up of the web UI.

Usage:
    python tools/ui_live_probe.py COM13 8

Prints one summary line per frame plus an aggregate at the end:
frame rate, timbre/keys/voices changes, latency stats, scan period.
"""
import sys
import time
from collections import Counter

import numpy as np
import serial

FRAME_LEN = 576
MAGIC = b"\xA5\x5A"
CLK_HZ = 27e6


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "COM13"
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 8.0

    ser = serial.Serial(port, 115200, timeout=0.05)
    buf = bytearray()
    t0 = time.time()
    while time.time() - t0 < secs:
        chunk = ser.read(8192)
        if chunk:
            buf.extend(chunk)
    ser.close()
    dt = time.time() - t0

    frames = []
    i = 0
    while True:
        j = buf.find(MAGIC, i)
        if j < 0 or j + FRAME_LEN > len(buf):
            break
        frames.append(bytes(buf[j:j + FRAME_LEN]))
        i = j + FRAME_LEN

    print("port=%s  window=%.1fs  bytes=%d  frames=%d  fps=%.2f"
          % (port, dt, len(buf), len(frames), len(frames) / dt))
    if not frames:
        return 1

    print("\n idx  t(ms)  tmb keys  voc flg eff  peak   lat_last    lat_min    lat_max    lat_cnt  scan_period  hist")
    last_tmb = None
    key_hist = Counter()
    tmb_hist = Counter()
    lat_last, lat_min, lat_max, lat_sum, lat_cnt, scan = [], [], [], [], [], []
    fp = time.time()

    for n, f in enumerate(frames):
        timbre = f[2] & 0x07
        keys = f[3] | ((f[4] & 0x0F) << 8)
        voices = f[5]
        flags = f[6]
        eff = f[7] & 0x03
        raw = np.frombuffer(f[8:520], dtype=np.uint8).astype(np.float64)
        peak = np.max(np.abs((raw - 128.0) / 128.0))
        u32 = lambda o: int.from_bytes(f[o:o + 4], "little")
        u16 = lambda o: int.from_bytes(f[o:o + 2], "little")
        ll, lmin, lmax, lsum = u32(520), u32(524), u32(528), u32(532)
        lcnt = u16(536)
        sc = u32(540)
        hist = list(f[544:556])

        key_hist[keys] += 1
        tmb_hist[timbre] += 1
        lat_last.append(ll); lat_min.append(lmin); lat_max.append(lmax)
        lat_sum.append(lsum); lat_cnt.append(lcnt); scan.append(sc)

        if n % 5 == 0 or flags or timbre != last_tmb:
            print(" %3d %6.1f  %d  0x%03X  %d  %d   %d  %.2f  %8d  %8d  %8d  %5d  %8d  %s"
                  % (n, (time.time() - fp) * 1000, timbre, keys, voices,
                     flags & 1, eff, peak, ll, lmin, lmax, lcnt, sc, hist))
        last_tmb = timbre

    ms = lambda v: v / CLK_HZ * 1e3
    print("\n--- aggregate ---")
    print("  distinct keys values : %s" % dict((hex(k), c) for k, c in key_hist.items()))
    print("  distinct timbre      : %s" % dict(tmb_hist))
    print("  scan_period          : %s" % sorted(set(scan)))
    if scan and scan[0]:
        print("    -> %.3f ms  (%.2f fps if that is the frame period)" % (ms(scan[0]), 1e3 / ms(scan[0])))
    ll = np.array(lat_last, dtype=np.float64)
    lm = np.array(lat_min, dtype=np.float64)
    lx = np.array(lat_max, dtype=np.float64)
    print("  lat_last  min/avg/max: %.3f / %.3f / %.3f ms"
          % (ms(ll.min()), ms(ll.mean()), ms(ll.max())))
    print("  lat_min   min/avg/max: %.3f / %.3f / %.3f ms"
          % (ms(lm.min()), ms(lm.mean()), ms(lm.max())))
    print("  lat_max   min/avg/max: %.3f / %.3f / %.3f ms"
          % (ms(lx.min()), ms(lx.mean()), ms(lx.max())))
    print("  lat_cnt  last        : %d" % lat_cnt[-1])
    return 0


if __name__ == "__main__":
    sys.exit(main())
