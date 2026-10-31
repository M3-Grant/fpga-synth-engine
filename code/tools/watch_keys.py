#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
持续监听串口帧，记录 keys 字段的变化序列。

用法（标定 TTP229 位映射）：
    python tools/watch_keys.py COM12 20

操作：脚本启动后，从左到右依次按 12 个触摸键，每个停约 1 秒。
输出：每次 keys 变化时打印位号（bit index）并保留顺序。
"""
import sys
import time
import numpy as np
import serial

FRAME_LEN = 576
MAGIC = b"\xA5\x5A"


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "COM12"
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 20.0

    ser = serial.Serial(port, 115200, timeout=0.05)
    buf = bytearray()
    t0 = time.time()
    last_keys = None
    events = []

    print("listening %s for %.0f s ..." % (port, secs))
    print("现在请【从左到右依次按 12 个键，每个停约 1 秒】")
    print("-" * 60)
    print("%-6s %-8s %s" % ("t(s)", "keys", "按下的位号"))

    while time.time() - t0 < secs:
        chunk = ser.read(2048)
        if not chunk:
            continue
        buf.extend(chunk)

        # 抽帧
        while True:
            j = buf.find(MAGIC)
            if j < 0 or j + FRAME_LEN > len(buf):
                if j > 0:
                    del buf[:j]
                break
            if j > 0:
                del buf[:j]
            f = bytes(buf[:FRAME_LEN])
            del buf[:FRAME_LEN]

            keys = f[3] | ((f[4] & 0x0F) << 8)
            if keys != last_keys:
                t = time.time() - t0
                bits = ",".join(str(i) for i in range(12) if (keys >> i) & 1) or "-"
                print("%-6.1f 0x%03X    %s" % (t, keys, bits))
                events.append((round(t, 1), keys))
                last_keys = keys

    ser.close()

    print("\n" + "=" * 60)
    print("共记录 %d 次变化" % len(events))
    print("\n按键事件序列：")
    for t, k in events:
        bits = [i for i in range(12) if (k >> i) & 1]
        print("  t=%5.1fs  keys=0x%03X  位号=%s" % (t, k, bits if bits else "无"))

    # 尝试推断：单键事件按时间排序 -> 物理位置（左->右）
    singles = [(t, k) for t, k in events if bin(k).count("1") == 1]
    if len(singles) >= 3:
        print("\n单键事件（按时间顺序 = 从左到右）：")
        for idx, (t, k) in enumerate(singles):
            bit = (k.bit_length() - 1)
            print("  第 %2d 次按 -> bit %d" % (idx + 1, bit))
        bits = [(k.bit_length() - 1) for _, k in singles]
        if bits == sorted(bits, reverse=True):
            print("\n>>> 位号随时间【递减】-> 低音在高位，映射表要反着填")
        elif bits == sorted(bits):
            print("\n>>> 位号随时间【递增】-> 低音在低位，默认映射就是对的")
        else:
            print("\n>>> 位号顺序不规律，需要人工核对")
    return 0


if __name__ == "__main__":
    sys.exit(main())
