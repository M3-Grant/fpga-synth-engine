# -*- coding: utf-8 -*-
"""
噪声基线分析 —— 对比电源改造每一步的频谱

用法：
    python analyze_noise.py a.wav                # 单文件分析
    python analyze_noise.py a.wav b.wav c.wav    # 多文件对比（打印每一步的差值）

判据（与 HANDOFF.md 6.4 一致）：
    1k/2k/5k/10k 谐波下降 ≥10 dB  → 明显有效
                     3~10 dB  → 部分有效，继续下一步
                      <3 dB  → 该步无效

不需要 scipy，只用 numpy + 标准库 wave。
"""
import os
import sys
import wave

import numpy as np

F0 = 440.0          # tone_test 的基频
HARMONICS = [440, 880, 1320, 1760, 2200, 2640]   # 基波 + 高次谐波
WATCH = [1000, 2000, 5000, 10000]                # HANDOFF 里点名的四个频点
BAND_LOW = (20.0, 500.0)                         # 宽带低频噪声
BAND_HIGH = (5000.0, 18000.0)                    # 高频沙沙


def load_wav(path):
    """读 16/24/32-bit PCM wav，返回 (float64 samples in [-1,1], fs)"""
    with wave.open(path, "rb") as w:
        nch, sw, fs, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if sw == 2:
        x = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    elif sw == 1:
        x = (np.frombuffer(raw, dtype=np.uint8).astype(np.float64) - 128.0) / 128.0
    elif sw == 3:
        b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3)
        v = (b[:, 0].astype(np.int32) | (b[:, 1].astype(np.int32) << 8)
             | (b[:, 2].astype(np.int32) << 16))
        v = np.where(v & 0x800000, v - 0x1000000, v)
        x = v.astype(np.float64) / 8388608.0
    else:
        raise SystemExit(f"不支持的位深: {sw * 8} bit")
    if nch > 1:
        x = x.reshape(-1, nch).mean(axis=1)
    return x, fs


def spectrum(x, fs):
    """取音量最大的 3 秒做 FFT，返回 (freqs, dB)"""
    win_n = int(3.0 * fs)
    if win_n > len(x):
        win_n = len(x)
    # 用能量最大的窗口（避开开头静音段）
    hop = max(1, win_n // 4)
    best, best_e = 0, -1.0
    for s in range(0, max(1, len(x) - win_n + 1), hop):
        e = float(np.sum(x[s:s + win_n] ** 2))
        if e > best_e:
            best_e, best = e, s
    seg = x[best:best + win_n]
    if len(seg) < 1024:
        raise SystemExit("音频太短（至少 0.2 秒）")
    w = np.hanning(len(seg))
    mag = np.abs(np.fft.rfft(seg * w)) / (np.sum(w) / 2.0)
    db = 20.0 * np.log10(np.maximum(mag, 1e-12))
    freqs = np.fft.rfftfreq(len(seg), 1.0 / fs)
    return freqs, db


def level_at(freqs, db, f, half_bw=8.0):
    """取 f 附近 ±half_bw Hz 的最大 dB（找峰，避开频点偏差）"""
    sel = (freqs >= f - half_bw) & (freqs <= f + half_bw)
    if not np.any(sel):
        k = int(np.argmin(np.abs(freqs - f)))
        return float(db[k])
    return float(db[sel].max())


def band_level(freqs, db, lo, hi):
    """频带内 dB 的 90 分位（代表该带的“常态”电平）"""
    sel = (freqs >= lo) & (freqs <= hi)
    if not np.any(sel):
        return float("nan")
    return float(np.percentile(db[sel], 90))


def analyze(path):
    x, fs = load_wav(path)
    dur = len(x) / fs
    peak = float(np.max(np.abs(x))) if len(x) else 0.0
    freqs, db = spectrum(x, fs)
    r = {
        "path": os.path.basename(path),
        "fs": fs,
        "dur": dur,
        "peak": peak,
        "rms_db": 20.0 * np.log10(max(np.sqrt(np.mean(x ** 2)), 1e-12)),
        "watch": {f: level_at(freqs, db, f) for f in WATCH},
        "harm": {f: level_at(freqs, db, f) for f in HARMONICS},
        "band_low": band_level(freqs, db, *BAND_LOW),
        "band_high": band_level(freqs, db, *BAND_HIGH),
        "floor": float(np.percentile(db[(freqs > 200) & (freqs < 18000)], 50)),
    }
    return r, (freqs, db)


def show(r):
    print(f"\n=== {r['path']} ===")
    print(f"  fs={r['fs']} Hz  时长={r['dur']:.2f}s  峰值={r['peak']:.4f}  RMS={r['rms_db']:.1f} dBFS")
    print(f"  440 Hz 基波      : {r['harm'][440]:7.1f} dB")
    print("  谐波系列 1/2/3/4/5/6 次:")
    print("    " + "  ".join(f"{f}Hz={r['harm'][f]:.1f}" for f in HARMONICS))
    print("  关注频点（HANDOFF 6.4）:")
    print("    " + "  ".join(f"{f}Hz={r['watch'][f]:.1f}" for f in WATCH))
    print(f"  宽带 20~500 Hz   : {r['band_low']:7.1f} dB")
    print(f"  宽带 5k~18k Hz   : {r['band_high']:7.1f} dB")
    print(f"  中位噪声底        : {r['floor']:7.1f} dB")


def compare(base, other):
    print(f"\n--- {other['path']} 相对 {base['path']} ---")
    for f in WATCH:
        d = other["watch"][f] - base["watch"][f]
        flag = "✅ 明显有效" if d <= -10 else ("有效但不彻底" if d <= -3 else "无效")
        print(f"  {f:>6} Hz : {d:+7.1f} dB   {flag}")
    for name, key in (("20~500Hz", "band_low"), ("5k~18kHz", "band_high")):
        d = other[key] - base[key]
        print(f"  {name:>9} : {d:+7.1f} dB")
    print(f"  中位噪声底     : {other['floor'] - base['floor']:+7.1f} dB")


def plot(results, out="noise_compare.png"):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    matplotlib.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
    matplotlib.rcParams["axes.unicode_minus"] = False

    fig = plt.figure(figsize=(12, 5), dpi=110)
    ax = fig.add_subplot(111)
    for r, (freqs, db) in results:
        sel = (freqs >= 20) & (freqs <= 18000)
        ax.semilogx(freqs[sel], db[sel], lw=0.8, label=r["path"])
    for f in WATCH:
        ax.axvline(f, color="#e06060", ls="--", lw=0.8, alpha=0.6)
    ax.set_xlim(20, 18000)
    ax.set_xlabel("频率 Hz")
    ax.set_ylabel("幅度 dB")
    ax.set_title("噪声频谱对比（红虚线 = 1k/2k/5k/10k 关注点）")
    ax.grid(True, which="both", alpha=0.25)
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(out)
    print(f"\n频谱图已保存: {out}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    results, rows = [], []
    for p in sys.argv[1:]:
        if not os.path.exists(p):
            print(f"找不到文件: {p}")
            continue
        r, spec = analyze(p)
        show(r)
        results.append((r, spec))
        rows.append(r)
    for r in rows[1:]:
        compare(rows[0], r)
    if results:
        plot(results)


if __name__ == "__main__":
    main()
