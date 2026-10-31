#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
验证 FPGA 是否在按 576 字节协议发串口帧。

用法：
    python tools/probe_uart_frame.py COM12 3

输出：找到的帧数、帧头、音色/按键/声部、采样统计、延迟字段。
"""
import sys
import time
import numpy as np
import serial

FRAME_LEN = 576
MAGIC = b"\xA5\x5A"


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "COM12"
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0

    ser = serial.Serial(port, 115200, timeout=0.05)
    buf = bytearray()
    frames = 0
    t0 = time.time()

    print("listening on %s @115200 for %.1f s ..." % (port, secs))
    while time.time() - t0 < secs:
        chunk = ser.read(4096)
        if chunk:
            buf.extend(chunk)

    ser.close()

    print("bytes received: %d" % len(buf))

    # 逐帧解析
    i = 0
    while True:
        j = buf.find(MAGIC, i)
        if j < 0 or j + FRAME_LEN > len(buf):
            break
        f = bytes(buf[j:j + FRAME_LEN])
        frames += 1

        if frames <= 5:
            timbre = f[2] & 0x07
            keys = f[3] | ((f[4] & 0x0F) << 8)
            voices = f[5]
            flags = f[6]
            eff = f[7] & 0x03
            raw = np.frombuffer(f[8:520], dtype=np.uint8).astype(np.float64)
            samples = (raw - 128.0) / 128.0
            lat_last = int.from_bytes(f[520:524], "little")
            lat_min = int.from_bytes(f[524:528], "little")
            print("\n--- frame %d (offset %d) ---" % (frames, j))
            print("  timbre=%d  keys=0x%03X (popcount=%d)  voices=%d  flags=0x%02X  eff=%d"
                  % (timbre, keys, bin(keys).count("1"), voices, flags, eff))
            print("  samples: min=%.3f max=%.3f mean=%.3f peak=%.3f"
                  % (samples.min(), samples.max(), samples.mean(), np.max(np.abs(samples))))
            print("  lat: last=%d min=%d (0xFFFFFFFF = no data)"
                  % (lat_last, lat_min))
        i = j + FRAME_LEN

    print("\n" + "=" * 60)
    if frames == 0:
        print("RESULT: NO VALID FRAME FOUND")
        print("  - 确认 USB-TTL 的 RXD 接到了 FPGA 引脚 48")
        print("  - 确认 GND 已连、电平跳线在 3V3")
        print("  - 确认波特率 115200")
        return 1
    print("RESULT: %d valid frame(s) found" % frames)
    print("  -> 固件串口输出正常，可以直接用 synth_viz.py --port %s" % port)
    return 0


if __name__ == "__main__":
    sys.exit(main())
