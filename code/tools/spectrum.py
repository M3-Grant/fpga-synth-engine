"""音频频谱分析 —— 生成频谱图并检验信号正确性。

用途：
    1) 直观看到音频的时域波形与频域频谱
    2) 验证方波的谐波结构（方波只有奇次谐波，偶次应被抑制）
    3) 检查音准（峰值频率应与音符理论频率一致）

用法：
    python spectrum.py                    # 分析 synth_demo_44k.wav
    python spectrum.py -f xxx.wav         # 指定文件
    python spectrum.py -t 0.5 1.5         # 只分析 0.5~1.5 秒区间
"""
import os
import wave
import struct
import argparse

import numpy as np
import matplotlib
matplotlib.use("Agg")          # 不弹窗，直接存图
import matplotlib.pyplot as plt
from matplotlib import font_manager


def setup_cjk_font():
    """挑一个能显示中文的字体。"""
    prefer = ["Microsoft YaHei", "SimHei", "SimSun", "DengXian", "Arial Unicode MS"]
    have = {f.name for f in font_manager.fontManager.ttflist}
    for name in prefer:
        if name in have:
            plt.rcParams["font.sans-serif"] = [name]
            plt.rcParams["axes.unicode_minus"] = False
            return name
    plt.rcParams["axes.unicode_minus"] = False
    return None


def read_wav(path):
    """返回 (samples_int16, sample_rate)。"""
    with wave.open(path, "rb") as w:
        ch = w.getnchannels()
        sw = w.getsampwidth()
        fr = w.getframerate()
        nf = w.getnframes()
        raw = w.readframes(nf)
    if sw != 2:
        raise ValueError("只支持 16bit WAV，当前 %d bit" % (sw * 8))
    data = np.frombuffer(raw, dtype="<i2").astype(np.float64)
    if ch > 1:
        data = data.reshape(-1, ch).mean(axis=1)
    return data, fr


# 常见音符（用于自动判断音准）
NOTES = {
    "C4": 261.63, "C#4": 277.18, "D4": 293.66, "D#4": 311.13,
    "E4": 329.63, "F4": 349.23, "F#4": 369.99, "G4": 392.00,
    "G#4": 415.30, "A4": 440.00, "A#4": 466.16, "B4": 493.88,
    "C5": 523.25, "D5": 587.33, "E5": 659.25, "G5": 783.99,
}


def nearest_note(freq):
    best, bd = None, 1e9
    for name, f in NOTES.items():
        d = abs(f - freq)
        if d < bd:
            bd, best = d, name
    cents = 1200 * np.log2(freq / NOTES[best]) if freq > 0 else 0
    return best, NOTES[best], cents


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-f", "--file", default=r"D:\harness\fpga-synth-engine\code\synth_demo_44k.wav")
    ap.add_argument("-t", "--time", nargs=2, type=float, default=None,
                    help="分析区间（秒），如 -t 0.5 1.5")
    ap.add_argument("-n", "--nfft", type=int, default=32768)
    ap.add_argument("-o", "--out", default=None)
    args = ap.parse_args()

    font = setup_cjk_font()
    if not os.path.exists(args.file):
        print("[错误] 找不到文件:", args.file)
        return 1

    data, fs = read_wav(args.file)
    total = len(data) / float(fs)
    print("=== 文件 ===")
    print("  路径   : %s" % args.file)
    print("  采样率 : %d Hz" % fs)
    print("  采样数 : %d" % len(data))
    print("  时长   : %.3f 秒" % total)
    print("  字体   : %s" % (font or "(无中文字体，图中用英文)"))

    # ---- 选取分析区间 ----
    if args.time:
        t0, t1 = args.time
        i0 = int(max(0, t0) * fs)
        i1 = int(min(total, t1) * fs)
    else:
        i0, i1 = 0, len(data)
    seg = data[i0:i1]
    if len(seg) < 1024:
        print("[错误] 区间太短")
        return 1

    # ---- FFT ----
    n = min(args.nfft, len(seg))
    win = np.hanning(n)
    spec = np.fft.rfft(seg[:n] * win)
    mag = np.abs(spec) / (n / 2.0)
    freqs = np.fft.rfftfreq(n, d=1.0 / fs)

    # ---- 找峰值（排除直流附近）----
    valid = freqs > 40
    fm, mm = freqs[valid], mag[valid]
    peak_idx = np.argsort(mm)[::-1][:8]
    peaks = sorted([(fm[i], mm[i]) for i in peak_idx if mm[i] > mm.max() * 0.05])

    print()
    print("=== 频谱峰值（前 8 个）===")
    print("  %-10s %-12s %-10s %s" % ("频率Hz", "幅度", "最近音符", "音分偏差"))
    for f, m in peaks[:8]:
        name, nf, cents = nearest_note(f)
        print("  %-10.1f %-12.1f %-10s %+.1f" % (f, m, name, cents))

    # ---- 方波谐波检验 ----
    print()
    print("=== 方波谐波检验 ===")
    print("  理论：方波只含奇次谐波（1f, 3f, 5f, 7f...），偶次应被抑制")
    if peaks:
        f0 = peaks[0][0]
        a0 = peaks[0][1]
        print("  基频 f0 = %.1f Hz" % f0)
        for k in range(1, 8):
            target = f0 * k
            # 找最接近的峰
            cand = min(peaks, key=lambda p: abs(p[0] - target))
            ratio = cand[1] / a0 if a0 > 0 else 0
            kind = "奇" if k % 2 == 1 else "偶"
            flag = ""
            if k % 2 == 1 and ratio > 0.05:
                flag = "  <- 奇次谐波，符合预期"
            if k % 2 == 0 and ratio < 0.05:
                flag = "  <- 偶次被抑制，符合方波特征"
            if k % 2 == 0 and ratio > 0.15:
                flag = "  <- 偶次偏高，可能不是纯方波"
            print("    %d×f0 = %7.1f Hz  实测 %7.1f Hz  幅度比 %.3f (%s次)%s"
                  % (k, target, cand[0], ratio, kind, flag))

    # ---- 复音检验：找独立谱峰 ----
    print()
    print("=== 独立谱峰检测（复音验证）===")
    thr = mm.max() * 0.10
    strong = [(fm[i], mm[i]) for i in range(len(fm)) if mm[i] > thr]
    merged = []
    for f, m in strong:
        if not merged or f - merged[-1][0] > 30:
            merged.append([f, m])
        elif m > merged[-1][1]:
            merged[-1] = [f, m]
    print("  幅度 > 10%% 峰值的独立谱峰数: %d" % len(merged))
    for f, m in merged[:10]:
        name, nf, cents = nearest_note(f)
        print("    %7.1f Hz  幅度 %7.1f  (接近 %s)" % (f, m, name))

    # ---- 绘图 ----
    fig, axes = plt.subplots(2, 1, figsize=(13, 8))

    # 上图：时域波形（只画前 30ms，看得到波形形状）
    show_n = int(0.03 * fs)
    t = np.arange(show_n) / float(fs) * 1000.0
    axes[0].plot(t, seg[:show_n], linewidth=0.9, color="#1f77b4")
    axes[0].set_title("Waveform (first 30 ms) - square wave with ADSR envelope",
                      fontsize=12)
    axes[0].set_xlabel("Time (ms)")
    axes[0].set_ylabel("Amplitude")
    axes[0].grid(alpha=0.3)

    # 下图：频谱
    lim = min(6000, fm[-1])
    sel = fm <= lim
    axes[1].plot(fm[sel], mm[sel], linewidth=0.9, color="#d62728")
    axes[1].set_title("Spectrum (FFT, n=%d)" % n, fontsize=12)
    axes[1].set_xlabel("Frequency (Hz)")
    axes[1].set_ylabel("Magnitude")
    axes[1].grid(alpha=0.3)
    # 标出前几个峰
    for f, m in peaks[:5]:
        if f <= lim:
            axes[1].annotate("%.0fHz" % f, xy=(f, m), xytext=(f, m * 1.08),
                             fontsize=8, ha="center", color="#2ca02c")

    fig.tight_layout()
    out = args.out or os.path.join(os.path.dirname(args.file), "spectrum.png")
    fig.savefig(out, dpi=110)
    plt.close(fig)
    print()
    print("=== 已生成频谱图 ===")
    print("  %s" % out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
