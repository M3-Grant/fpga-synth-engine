#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
验证上位机下行命令：发 0xA5 0x01 <wave>，然后读帧确认 timbre 变了。

用法：
    python tools/test_ui_cmd.py COM12
"""
import sys
import time
import serial

FRAME_LEN = 576
MAGIC = b"\xA5\x5A"
TIMBRE_NAMES = ["三角", "方波", "锯齿", "脉冲", "钢琴"]


def read_frame(ser, timeout=1.0):
    """读一帧，返回 timbre（失败返回 None）"""
    buf = bytearray()
    t0 = time.time()
    while time.time() - t0 < timeout:
        chunk = ser.read(1024)
        if chunk:
            buf.extend(chunk)
            j = buf.find(MAGIC)
            if j >= 0 and j + FRAME_LEN <= len(buf):
                f = bytes(buf[j:j + FRAME_LEN])
                return f[2] & 0x07
    return None


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "COM12"
    ser = serial.Serial(port, 115200, timeout=0.1)
    time.sleep(0.5)

    print("port = %s" % port)
    print("-" * 56)

    ok = 0
    total = 0
    for wave in range(5):
        # 稍微清一下接收缓冲
        ser.reset_input_buffer()
        ser.write(bytes([0xA5, 0x01, wave]))
        ser.flush()
        time.sleep(0.3)

        t = read_frame(ser)
        total += 1
        if t == wave:
            print("  send wave=%d -> timbre=%d (%s)  OK" % (wave, t, TIMBRE_NAMES[t]))
            ok += 1
        elif t is None:
            print("  send wave=%d -> NO FRAME RECEIVED" % wave)
        else:
            print("  send wave=%d -> timbre=%d (%s)  MISMATCH" % (wave, t, TIMBRE_NAMES[t]))
        time.sleep(0.2)

    # 回到钢琴
    ser.write(bytes([0xA5, 0x01, 4]))
    ser.close()

    print("-" * 56)
    print("%d / %d passed" % (ok, total))
    return 0 if ok == total else 1


if __name__ == "__main__":
    sys.exit(main())
