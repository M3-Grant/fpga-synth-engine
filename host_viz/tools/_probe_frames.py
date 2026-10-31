# -*- coding: utf-8 -*-
"""用上位机自己的串口读取器探测板载 COM 口是否传来 576 字节帧"""
import sys
import time

sys.path.insert(0, r"D:\Date\DeepseekDate\viz")
from synth_viz import SerialReader

port = sys.argv[1] if len(sys.argv) > 1 else "COM8"
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0

frames = []


def on_frame(timbre, keys, voices, eff, samples, lat):
    frames.append((timbre, keys, voices, lat))


r = SerialReader(port, 115200, on_frame)
r.start()
time.sleep(0.4)
if not r.ok:
    print(f"[{port}] 打不开: {r.err}", flush=True)
    sys.exit(0)

time.sleep(secs)
r.stop()
time.sleep(0.2)

print(f"[{port}] 收到完整帧 {len(frames)} 个", flush=True)
if not frames:
    sys.exit(0)

ks = sorted({f[1] for f in frames})
print(f"  出现过的按键位图: {[hex(k) for k in ks]}", flush=True)

for i, (timbre, keys, voices, lat) in enumerate(frames[:4]):
    print(f"  frame{i}: timbre={timbre} keys=0x{keys:03X} voices={voices} "
          f"lat={lat['last']}({lat['last'] / 27000:.3f} ms) cnt={lat['cnt']} "
          f"scan={lat['scan'] / 27000:.2f} ms", flush=True)

lats = [f[3]["last"] / 27000.0 for f in frames if f[3]["cnt"]]
if lats:
    print(f"  延迟: min={min(lats):.3f}  max={max(lats):.3f}  n={len(lats)} ms",
          flush=True)
