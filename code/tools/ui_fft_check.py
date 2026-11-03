#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Reconstruct the true effective sample rate of the 512-sample payload in the
576-byte UI frame, by comparing the FFT peak against the expected note.

Run against self_test_uart (auto 12-note loop, DECIM=7) or synth_ttp229.

    python tools/ui_fft_check.py COM13 6
"""
import sys
import time

import numpy as np
import serial

FRAME_LEN = 576
MAGIC = b"\xA5\x5A"
FS_AUDIO = 52734.375
NOTES = ["C4", "C#4", "D4", "D#4", "E4", "F4", "F#4", "G4", "G#4", "A4", "A#4", "B4"]
# equal-tempered, C4 = 261.6256
EXPECT = [261.6256 * 2 ** (i / 12.0) for i in range(12)]


def grab(port, secs):
    ser = serial.Serial(port, 115200, timeout=0.05)
    buf = bytearray()
    t0 = time.time()
    while time.time() - t0 < secs:
        chunk = ser.read(8192)
        if chunk:
            buf.extend(chunk)
    ser.close()
    frames = []
    i = 0
    while True:
        j = buf.find(MAGIC, i)
        if j < 0 or j + FRAME_LEN > len(buf):
            break
        frames.append(bytes(buf[j:j + FRAME_LEN]))
        i = j + FRAME_LEN
    return frames


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "COM13"
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 6.0
    frames = grab(port, secs)
    print("frames=%d in %.1fs  (%.2f fps)" % (len(frames), secs, len(frames) / secs))
    if not frames:
        return 1

    print("\n idx  key        peak_bin  f_if_fs/512   f_if_fs/512/7   nearest_note   err@/7")
    hits = 0
    for n, f in enumerate(frames):
        keys = f[3] | ((f[4] & 0x0F) << 8)
        s = np.frombuffer(f[8:520], dtype=np.uint8).astype(np.float64) - 128.0
        if np.max(np.abs(s)) < 4:
            continue                                  # silence
        if keys == 0 or bin(keys).count("1") != 1:
            continue
        note = keys.bit_length() - 1
        w = np.hanning(512)
        sp = np.abs(np.fft.rfft(s * w, n=4096))
        # ignore DC / very low bins
        k = int(np.argmax(sp[3:])) + 3
        f_raw = k * FS_AUDIO / 4096.0                 # if payload were at full fs
        f_dec = k * (FS_AUDIO / 7.0) / 4096.0         # if payload is decimated by 7
        exp = EXPECT[note]
        err = 1200 * np.log2(max(f_dec, 1e-9) / exp)  # cents
        near = int(np.argmin([abs(1200 * np.log2(f_raw / e)) for e in EXPECT]))
        print(" %3d  %-3s (0x%03X)  %6.2f   %9.1f Hz  %11.1f Hz   %-4s (%7.1f)  %+7.1f cents"
              % (n, NOTES[note], keys, k, f_raw, f_dec, NOTES[near],
                 1200 * np.log2(f_raw / EXPECT[near]), err))
        hits += 1
        if hits >= 14:
            break

    print("\n结论判据：如果 f_if_fs/512/7 与 expected 的误差 < 50 cents，"
          "则 payload 是真抽取（有效采样率 = 52734/7 = 7533.5 Hz），"
          "UI 里 binHz = SAMPLE_RATE/512 = 103 Hz 就是错的（应为 14.7 Hz）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
