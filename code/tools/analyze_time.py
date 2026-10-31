#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
按时间分段看若干频点的幅度变化，区分"信号"与"环境/独立干扰"。

判读规则：
  · 某频点只在发声期间出现 -> 与音频链路相关（信号或其失真产物）
  · 某频点全程恒定        -> 环境噪声 / 时钟泄漏 / 电源纹波
  · 两个频点同步起伏      -> 同源（例如 f 与 2f 是基波与谐波）

用法：
    python tools/analyze_time.py <录音.wav> [频率1 频率2 ...]
"""
import sys
import numpy as np
from scipy.io import wavfile


def load(path):
    fs, d = wavfile.read(path)
    d = d.astype(np.float64)
    if d.ndim > 1:
        d = d.mean(axis=1)
    if np.max(np.abs(d)) > 1.5:
        d = d / 32768.0
    return d, fs


def band_mag(seg, fs, freq, nfft=8192, tol=12.0):
    n = min(len(seg), nfft)
    if n < 512:
        return 0.0
    w = np.hanning(n)
    s = np.abs(np.fft.rfft((seg[:n] - seg[:n].mean()) * w, nfft)) * 2 / w.sum()
    f = np.fft.rfftfreq(nfft, 1.0 / fs)
    m = np.abs(f - freq) <= tol
    return float(np.max(s[m])) if np.any(m) else 0.0


def main():
    if len(sys.argv) < 2:
        print("usage: analyze_time.py <wav> [freq ...]")
        return 2
    path = sys.argv[1]
    freqs = [float(x) for x in sys.argv[2:]] or [210.9, 261.6, 440.0, 10007.0]

    x, fs = load(path)
    dur = len(x) / fs
    print("=" * 70)
    print("  分段时间分析：%s  (%.2f s @ %d Hz)" % (path.split("\\")[-1], dur, fs))
    print("=" * 70)

    # 0.5 s 一窗
    win = int(0.5 * fs)
    nwin = len(x) // win
    rows = []
    for k in range(nwin):
        seg = x[k * win:(k + 1) * win]
        rms = np.sqrt(np.mean(seg ** 2))
        vals = [band_mag(seg, fs, f) for f in freqs]
        rows.append((k * 0.5, rms, vals))

    # 表头
    hdr = "  时间(s)   RMS      " + "".join("%11.1f" % f for f in freqs)
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))
    for t, rms, vals in rows:
        line = "  %6.1f   %7.4f  " % (t, rms)
        line += "".join("%11.5f" % v for v in vals)
        print(line)

    # 相关性：各频点与 RMS 的相关系数
    rms_arr = np.array([r[1] for r in rows])
    print("\n  -- 各频点与总响度(RMS)的相关系数 --")
    for i, f in enumerate(freqs):
        a = np.array([r[2][i] for r in rows])
        if np.std(a) < 1e-12 or np.std(rms_arr) < 1e-12:
            c = 0.0
        else:
            c = float(np.corrcoef(a, rms_arr)[0, 1])
        verdict = ""
        if c > 0.6:
            verdict = "  <- 与发声同步（信号或其失真）"
        elif abs(c) < 0.3:
            verdict = "  <- 与发声无关（环境/时钟/电源）"
        print("  %9.1f Hz : %+6.2f%s" % (f, c, verdict))

    print("=" * 70)
    return 0


if __name__ == "__main__":
    sys.exit(main())
