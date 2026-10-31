# -*- coding: utf-8 -*-
"""监控 COM9 的 keys 字段变化，用来判断 TTP229 的输出极性"""
import sys
import time

sys.path.insert(0, r"D:\Date\DeepseekDate\viz")
from synth_viz import SerialReader

port = sys.argv[1] if len(sys.argv) > 1 else "COM9"
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 45.0
out = r"D:\Date\DeepseekDate\viz\_keys_log.txt"

log = open(out, "w", encoding="utf-8")
seen = {}


def on_frame(timbre, keys, voices, eff, samples, lat):
    n = seen.get(keys, 0) + 1
    if keys not in seen:
        log.write(f"[{time.strftime('%H:%M:%S')}] NEW keys=0x{keys:03X} "
                  f"({keys:012b}) voices={voices}\n")
        log.flush()
    seen[keys] = n


r = SerialReader(port, 115200, on_frame)
r.start()
time.sleep(0.4)
if not r.ok:
    log.write(f"打不开 {port}: {r.err}\n")
    log.close()
    sys.exit(0)

log.write(f"开始监控 {port}，{secs:.0f} 秒\n")
log.flush()
time.sleep(secs)
r.stop()
time.sleep(0.2)

log.write("\n=== 汇总：出现过的 keys 值 ===\n")
for k, n in sorted(seen.items(), key=lambda x: -x[1]):
    log.write(f"  keys=0x{k:03X}（{k:012b}）  出现 {n} 次\n")
log.write(f"\n总共 {sum(seen.values())} 帧\n")
log.close()
print("done")
