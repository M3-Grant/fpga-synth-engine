# -*- coding: utf-8 -*-
"""看 FPGA 实际输出的音频采样：判断"没声音"是数字侧没生成，还是模拟侧被静音"""
import sys
import time

import numpy as np

sys.path.insert(0, r"D:\Date\DeepseekDate\viz")
from synth_viz import SerialReader

port = sys.argv[1] if len(sys.argv) > 1 else "COM9"
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0

rows = []


def on_frame(timbre, keys, voices, eff, samples, lat):
    pk = float(np.max(np.abs(samples)))
    rows.append((time.time(), keys, voices, pk, lat["last"]))


r = SerialReader(port, 115200, on_frame)
r.start()
time.sleep(0.4)
if not r.ok:
    print("打不开:", r.err)
    sys.exit(0)

time.sleep(secs)
r.stop()

print(f"收到 {len(rows)} 帧")
if not rows:
    sys.exit(0)

keys_seen = sorted({k for _, k, _, _, _ in rows})
print("出现过的 keys:", [hex(k) for k in keys_seen])

idle = [p for _, k, _, p, _ in rows if k == 0]
play = [p for _, k, _, p, _ in rows if k != 0]
print(f"空闲帧 {len(idle)} 个，采样峰值 最大={max(idle) if idle else 0:.3f} "
      f"平均={np.mean(idle) if idle else 0:.3f}")
print(f"按键帧 {len(play)} 个，采样峰值 最大={max(play) if play else 0:.3f} "
      f"平均={np.mean(play) if play else 0:.3f}")

peak_all = max(p for _, _, _, p, _ in rows)
print(f"\n总采样峰值 = {peak_all:.3f}  (0 = 完全静音, 1 = 满幅)")

if peak_all < 0.02:
    print(">>> 数字侧没有音频输出（波形是平的）→ 问题在 FPGA 内部")
else:
    print(">>> 数字侧有音频输出（波形非零）→ 问题在 DAC/功放/静音脚")
