#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
分析手机录音，定位板子输出的真实频率成分。

用途：新音频链路（PCM5102A + PAM8403）接上后，手机录一段，判断：
  1. 期望的音（例如 440 Hz）在不在、准不准
  2. 最强成分是什么频率（频谱截图里出现 10031 Hz 尖峰）
  3. 噪声底有多高、是宽带还是窄带
  4. 有没有工频（50/100 Hz）或开关纹波

用法：
    C:\\Python314\\python.exe tools\\analyze_recording.py <录音文件>
"""
import os
import sys
import numpy as np


def decode(path):
    """把录音解码成单声道 float64。WAV 走 scipy，其它格式走 PyAV。"""
    if path.lower().endswith(".wav"):
        from scipy.io import wavfile
        fs, data = wavfile.read(path)
        data = data.astype(np.float64)
        if data.ndim > 1:
            data = data.mean(axis=1)
        peak = np.max(np.abs(data)) if len(data) else 0
        if peak > 1.5:
            data = data / 32768.0
        return data, fs
    import av
    container = av.open(path)
    stream = next(s for s in container.streams if s.type == "audio")
    fs = stream.rate
    chunks = []
    for frame in container.decode(stream):
        arr = frame.to_ndarray()
        # 平面格式 (channels, samples) 或交错 (1, samples*ch)
        if arr.ndim == 2 and arr.shape[0] > 1:
            arr = arr.mean(axis=0)
        else:
            arr = arr.reshape(-1)
        chunks.append(arr.astype(np.float64))
    x = np.concatenate(chunks) if chunks else np.zeros(1)
    # 归一化到 ±1（不同格式位深不同）
    peak = np.max(np.abs(x)) if len(x) else 0
    if peak > 1.5:
        x = x / (32768.0 if peak > 100 else 1.0)
    return x, fs


def spectrum(x, fs, nfft=16384):
    n = min(len(x), nfft)
    w = np.hanning(n)
    seg = (x[:n] - np.mean(x[:n])) * w
    spec = np.fft.rfft(seg, nfft)
    freqs = np.fft.rfftfreq(nfft, 1.0 / fs)
    mags = np.abs(spec) * 2.0 / np.sum(w)
    return freqs, mags


def peaks(freqs, mags, n=12, min_gap_hz=30.0):
    """找局部极大值，按幅度排序。"""
    idx = []
    for i in range(1, len(mags) - 1):
        if mags[i] > mags[i - 1] and mags[i] >= mags[i + 1]:
            idx.append(i)
    idx.sort(key=lambda i: mags[i], reverse=True)
    out, used = [], []
    for i in idx:
        f = freqs[i]
        if any(abs(f - u) < min_gap_hz for u in used):
            continue
        used.append(f)
        out.append((f, mags[i]))
        if len(out) >= n:
            break
    return out


def db(x, ref):
    return 20 * np.log10(max(x, 1e-12) / max(ref, 1e-12))


def main():
    if len(sys.argv) < 2:
        print("用法: analyze_recording.py <录音文件>")
        return 2
    path = sys.argv[1]
    if not os.path.exists(path):
        print("找不到文件:", path)
        return 2

    x, fs = decode(path)
    print("=" * 66)
    print("  录音频谱分析")
    print("=" * 66)
    print("文件      : %s" % os.path.basename(path))
    print("解码采样率: %d Hz" % fs)
    print("时长      : %.2f s  (%d 样本)" % (len(x) / fs, len(x)))
    print("峰值      : %.4f" % np.max(np.abs(x)))
    print("RMS       : %.5f  (%.1f dBFS)" % (np.sqrt(np.mean(x ** 2)),
                                            20 * np.log10(max(np.sqrt(np.mean(x ** 2)), 1e-12))))

    # ---- 整体频谱 ----
    f, m = spectrum(x, fs)
    ref = np.max(m)
    print("\n-- 最强 12 个频率成分 --")
    print("  频率(Hz)     幅度      相对最强")
    for fr, mg in peaks(f, m, 12):
        print("  %9.1f  %9.6f    %7.1f dB" % (fr, mg, db(mg, ref)))

    # ---- 关键频点 ----
    def at(freq, tol=15.0):
        mask = np.abs(f - freq) <= tol
        return float(np.max(m[mask])) if np.any(mask) else 0.0

    print("\n-- 关键频点 --")
    for label, freq in [("440 Hz (tone_test 期望)", 440.0),
                        ("261.6 Hz (C4)", 261.6),
                        ("10031 Hz (截图尖峰)", 10031.0),
                        ("50 Hz (工频)", 50.0),
                        ("100 Hz (工频二次)", 100.0)]:
        v = at(freq)
        print("  %-26s %9.6f   %7.1f dB" % (label, v, db(v, ref)))

    # ---- 噪声底估计（中位幅度）----
    floor = float(np.median(m))
    print("\n噪声底（中位幅度）: %.3e  (%.1f dB 相对最强)" % (floor, db(floor, ref)))

    # ---- 判断 ----
    print("\n-- 判读 --")
    p = peaks(f, m, 6)
    top_f, top_m = p[0]
    if abs(top_f - 440.0) < 20:
        print("  ✅ 最强成分是 440 Hz，符合 tone_test 预期")
    else:
        print("  ⚠ 最强成分是 %.1f Hz，不是 440 Hz" % top_f)

    # 440 与最强的差距
    v440 = at(440.0)
    if ref > 0 and v440 > 0:
        print("  440 Hz 比最强成分低 %.1f dB" % db(v440, ref))

    # 谐波结构：以最强成分为 f0，看 2f0/3f0
    if top_f > 50:
        for k in (2, 3):
            v = at(top_f * k, tol=top_f * 0.02)
            print("  %d 倍频 (%.0f Hz): %.1f dB" % (k, top_f * k, db(v, ref)))

    print("=" * 66)
    return 0


if __name__ == "__main__":
    sys.exit(main())
