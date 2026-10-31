# -*- coding: utf-8 -*-
"""标定：同时记录映射后 12 位 与 TTP229 原始 16 位"""
import sys
import time

sys.path.insert(0, r"D:\Date\DeepseekDate\viz")
from synth_viz import SerialReader

port = sys.argv[1] if len(sys.argv) > 1 else "COM9"
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 120.0
out = r"D:\Date\DeepseekDate\viz\_keys_calib.txt"

log = open(out, "w", encoding="utf-8")
t0 = time.time()
last = None
seq = 0


class RawReader(SerialReader):
    def _parse(self):
        while True:
            i = self._buf.find(b"\xA5\x5A")
            if i < 0:
                if len(self._buf) > 4096:
                    self._buf = self._buf[-2:]
                return
            if i > 0:
                del self._buf[:i]
            if len(self._buf) < self.FRAME_LEN:
                return
            f = bytes(self._buf[:self.FRAME_LEN])
            del self._buf[:self.FRAME_LEN]
            keys = f[3] | ((f[4] & 0x0F) << 8)
            raw = int.from_bytes(f[538:540], "little")
            self.on_frame(keys, raw)


def on_frame(keys, raw):
    global last, seq
    if (keys, raw) == last:
        return
    t = time.time() - t0
    if keys == 0:
        log.write(f"{t:6.2f}s  松开\n")
    else:
        seq += 1
        bits = [i for i in range(12) if keys >> i & 1]
        rbits = [i for i in range(16) if raw >> i & 1]
        log.write(f"{t:6.2f}s  第 {seq:2d} 次  keys=0x{keys:03X}{bits}  "
                  f"raw=0x{raw:04X}{rbits}\n")
    log.flush()
    last = (keys, raw)


r = RawReader(port, 115200, on_frame)
r.start()
time.sleep(0.4)
if not r.ok:
    log.write(f"打不开 {port}: {r.err}\n")
    log.close()
    sys.exit(0)

log.write(f"开始标定 {port}，{secs:.0f} 秒\n")
log.flush()
time.sleep(secs)
r.stop()
log.write(f"\n共 {seq} 次按下\n")
log.close()
print("done")
