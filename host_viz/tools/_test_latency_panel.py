# -*- coding: utf-8 -*-
"""离线验证 synth_viz.py 的 576 字节帧解析 + 延迟面板渲染（不接板子）"""
import sys
import struct

import numpy as np

sys.path.insert(0, r"D:\Date\DeepseekDate\viz")
import synth_viz as sv
import matplotlib
matplotlib.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
matplotlib.rcParams["axes.unicode_minus"] = False

CLK = 27_000_000.0

# ---------------- 1) 造一个 576 字节帧 ----------------
f = bytearray(576)
f[0], f[1] = 0xA5, 0x5A
f[2] = 3                 # 音色：脉冲波
f[3] = 0b0000_1001       # key0, key3
f[4] = 0b0000_0001       # key8
f[5] = 3                 # 3 个声部
f[6] = 0x01              # 有延迟数据
f[7] = 0x00
for i in range(512):
    # 造一段像样的波形（3 个音叠加，偏移二进制）
    t = i / sv.FS
    v = 0.33 * (np.sin(2 * np.pi * 261.63 * t)
                + np.sin(2 * np.pi * 329.63 * t)
                + np.sin(2 * np.pi * 392.00 * t))
    f[8 + i] = int(round(128 + v * 120)) & 0xFF

last = int(1.238e-3 * CLK)
vmin = int(1.201e-3 * CLK)
vmax = int(1.312e-3 * CLK)
cnt = 57
ssum = int((1.245e-3 * CLK) * cnt) & 0xFFFFFFFF
scan = 540_000           # 20 ms 扫描间隔

struct.pack_into("<I", f, 520, last)
struct.pack_into("<I", f, 524, vmin)
struct.pack_into("<I", f, 528, vmax)
struct.pack_into("<I", f, 532, ssum)
struct.pack_into("<H", f, 536, cnt)
struct.pack_into("<I", f, 540, scan)

hist = np.zeros(16, dtype=np.uint16)
hist[0] = 4
hist[1] = 40
hist[2] = 13
struct.pack_into("<16H", f, 544, *[int(x) for x in hist])

# ---------------- 2) 走真实解析路径 ----------------
sr = sv.SerialReader.__new__(sv.SerialReader)
sr._buf = bytearray(f)
box = {}
sr.on_frame = lambda *a: box.setdefault("v", a)
sr._parse()

timbre, keys, voices, eff, samples, lat = box["v"]
print("timbre =", timbre, " keys =", bin(keys), " voices =", voices, " eff =", eff)
print("samples:", samples.shape, "min/max =", samples.min(), samples.max())
print("lat.last =", lat["last"], f'({lat["last"] / CLK * 1e3:.3f} ms)')
print("lat.min  =", lat["min"], f'({lat["min"] / CLK * 1e3:.3f} ms)')
print("lat.max  =", lat["max"], f'({lat["max"] / CLK * 1e3:.3f} ms)')
print("lat.cnt  =", lat["cnt"], " scan =", lat["scan"],
      f'({lat["scan"] / CLK * 1e3:.2f} ms)')
print("hist     =", lat["hist"].astype(int).tolist())
print("flag     =", lat["flag"])

assert timbre == 3 and keys == (1 << 0) | (1 << 3) | (1 << 8) and voices == 3
assert abs(lat["last"] / CLK * 1e3 - 1.238) < 0.01
assert abs(lat["scan"] / CLK * 1e3 - 20.0) < 0.01
assert lat["hist"].astype(int).tolist() == [4, 40, 13] + [0] * 13
print("\n[PARSE OK]")

# ---------------- 3) 渲染一帧，检查面板 ----------------
import tkinter as tk
root = tk.Tk()


class FakeSer:
    ok = True


app = sv.SynthViz(root)
app.serial = FakeSer()
app._on_serial_frame(timbre, keys, voices, eff, samples, lat)
app._render()
print("big text =", app.lat_big.get_text())
print("sub  =", app.lat_sub.get_text())
print("sub2 =", app.lat_sub2.get_text())
assert "1.238" in app.lat_big.get_text()
assert "20.0" in app.lat_sub2.get_text()
out = r"D:\Date\DeepseekDate\viz\preview_latency_serial.png"
app.fig.savefig(out, facecolor=app.fig.get_facecolor())
print("\n[RENDER OK] saved:", out)
root.destroy()
