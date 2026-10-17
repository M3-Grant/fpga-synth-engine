#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
验证 piano_engine 的音频输出是否真的具有"钢琴式谐波结构"。

输入：code/piano_dump.txt —— tb_piano_engine.v 导出的单音 C4 样本（每行一个整数）

检查项
  1. 峰值 / 是否削波
  2. 基频是否在 C4（261.63 Hz）附近
  3. 1..6 次谐波是否存在，且幅度随次数递减
  4. 音头窗口 vs 衰减后窗口：高次谐波相对基波的占比应下降（音色由亮变暗）

用法：
    C:\\Python314\\python.exe tools\\verify_piano.py            # 在 code 目录下运行
"""
import os
import sys

import numpy as np

FS      = 52734.375          # 采样率（27 MHz / 8 / 64）
F0      = 261.63             # C4 理论基频
HARM    = 6                  # 检查 1..6 次谐波
NFFT    = 4096               # 0.078 s（dump 只有 12000 点）


def load(path):
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        vals = [int(line) for line in f if line.strip()]
    return np.asarray(vals, dtype=np.float64)


def spectrum(x, fs=FS, nfft=NFFT):
    """返回 (freqs, mags)：加 Hann 窗、去直流、补零到 nfft。"""
    n = min(len(x), nfft)
    if n < 1024:
        raise ValueError("样本太少：%d" % n)
    w = np.hanning(n)
    seg = (x[:n] - np.mean(x[:n])) * w
    spec = np.fft.rfft(seg, nfft)
    freqs = np.fft.rfftfreq(nfft, 1.0 / fs)
    mags = np.abs(spec) * 2.0 / np.sum(w)
    return freqs, mags


def harm_amp(freqs, mags, k, f0=F0, tol=18.0):
    """取 k 次谐波附近（±tol Hz）的峰值幅度。"""
    target = k * f0
    mask = np.abs(freqs - target) <= tol
    if not np.any(mask):
        return 0.0
    return float(np.max(mags[mask]))


def peak_freq(freqs, mags, lo, hi):
    """用抛物线插值把峰值频率精化到 bin 以下精度。"""
    mask = (freqs > lo) & (freqs < hi)
    if not np.any(mask):
        return 0.0
    idxs = np.where(mask)[0]
    k = int(idxs[np.argmax(mags[idxs])])
    if 0 < k < len(mags) - 1:
        a, b, c = mags[k - 1], mags[k], mags[k + 1]
        den = a - 2 * b + c
        d = 0.5 * (a - c) / den if abs(den) > 1e-12 else 0.0
        return float(freqs[k] + d * (freqs[1] - freqs[0]))
    return float(freqs[k])


def db(x, ref):
    if ref <= 0 or x <= 0:
        return float("-inf")
    return 20.0 * np.log10(x / ref)


def main():
    base = os.path.dirname(os.path.abspath(__file__))
    cand = [
        os.path.join(base, "..", "piano_dump.txt"),
        os.path.join(base, "..", "..", "code", "piano_dump.txt"),
        "piano_dump.txt",
    ]
    path = next((p for p in cand if os.path.exists(p)), None)
    if path is None:
        print("[ERROR] 找不到 piano_dump.txt，先跑 tb_piano_engine")
        return 2

    x = load(path)
    print("=" * 62)
    print("  piano_engine 谐波验证")
    print("=" * 62)
    print("文件       : %s" % os.path.normpath(path))
    print("样本数     : %d  (%.3f s)" % (len(x), len(x) / FS))
    print("峰值       : %d" % int(np.max(np.abs(x))))
    print("RMS        : %.1f" % np.sqrt(np.mean(x ** 2)))

    fails = []
    if np.max(np.abs(x)) >= 32767:
        fails.append("输出削波（峰值 %d）" % int(np.max(np.abs(x))))
    if np.max(np.abs(x)) < 2000:
        fails.append("输出过小（峰值 %d < 2000）" % int(np.max(np.abs(x))))

    # ---------- 音头频谱 ----------
    f1, m1 = spectrum(x[:NFFT])
    a1 = [harm_amp(f1, m1, k) for k in range(1, HARM + 1)]
    # 基频实测（FFT bin 分辨率只有 12.9 Hz，用抛物线插值精化）
    f0_meas = peak_freq(f1, m1, 200.0, 340.0)

    print("\n-- 音头窗口（0 ~ %.0f ms）--" % (NFFT / FS * 1000))
    print("实测基频   : %.1f Hz  (理论 %.1f, 偏差 %+.2f%%)"
          % (f0_meas, F0, (f0_meas - F0) / F0 * 100 if f0_meas else 0))
    print("  谐波     幅度          相对基波")
    for k, a in enumerate(a1, 1):
        print("  %d 次    %10.1f    %7.1f dB" % (k, a, db(a, a1[0])))

    if abs(f0_meas - F0) > 6.0:
        fails.append("基频 %.1f Hz 偏离 C4 太多" % f0_meas)
    for k in range(1, HARM + 1):
        if a1[k - 1] <= 1.0:
            fails.append("第 %d 次谐波幅度过低（%.1f），谐波缺失" % (k, a1[k - 1]))
    # 单调递减（允许 3 dB 容差）
    for k in range(2, HARM + 1):
        if db(a1[k - 1], a1[0]) > db(a1[k - 2], a1[0]) + 3.0:
            fails.append("第 %d 次谐波比第 %d 次还强（不是钢琴式衰减）"
                         % (k, k - 1))

    # ---------- 衰减后频谱 ----------
    if len(x) >= 10100:
        f2, m2 = spectrum(x[6000:6000 + NFFT])
        a2 = [harm_amp(f2, m2, k) for k in range(1, HARM + 1)]
        print("\n-- 衰减后窗口（%.0f ~ %.0f ms）--"
              % (6000 / FS * 1000, (6000 + NFFT) / FS * 1000))
        print("  谐波     幅度          相对基波")
        for k, a in enumerate(a2, 1):
            print("  %d 次    %10.1f    %7.1f dB" % (k, a, db(a, a2[0])))
        if a2[1] > 1.0:
            hi1 = sum(a1[1:]) / max(a1[0], 1e-9)      # 音头的"高次/基波"比
            hi2 = sum(a2[1:]) / max(a2[0], 1e-9)
            print("\n高次谐波总占比：音头 %.2f  →  衰减后 %.2f" % (hi1, hi2))
            if hi2 >= hi1:
                fails.append("高次谐波没有随基波更快衰减（音色没有变暗）")

    print("\n" + "=" * 62)
    if fails:
        print("  验证失败：%d 项" % len(fails))
        for s in fails:
            print("    - %s" % s)
        print("=" * 62)
        return 1
    print("  谐波结构验证通过")
    print("=" * 62)
    return 0


if __name__ == "__main__":
    sys.exit(main())
