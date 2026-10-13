"""严格验证：方波谐波结构 + 复音独立谱峰。

针对本项目：
    单音段（0.3~1.0s） 应为纯方波 → 只有奇次谐波（1f 3f 5f ...）
    和弦段（1.7~2.6s） 应为 3 音叠加 → 应出现 C4/E4/G4 三组谱线

用法：
    python verify_spectrum.py
"""
import os
import wave
import numpy as np

BASE = r"D:\harness\fpga-synth-engine\code"
WAV = os.path.join(BASE, "synth_demo_44k.wav")

# C 大三和弦理论频率
CHORD = {"C4": 261.63, "E4": 329.63, "G4": 392.00}


def read_wav(path):
    with wave.open(path, "rb") as w:
        fs = w.getframerate()
        raw = w.readframes(w.getnframes())
    return np.frombuffer(raw, dtype="<i2").astype(np.float64), fs


def spectrum(seg, fs, nfft=65536):
    n = min(nfft, len(seg))
    win = np.hanning(n)
    spec = np.fft.rfft(seg[:n] * win)
    mag = np.abs(spec) / (n / 2.0)
    freqs = np.fft.rfftfreq(n, d=1.0 / fs)
    return freqs, mag


def find_peaks(freqs, mag, fmin=50, fmax=6000, top=40):
    """用简单的极大值检测找谱峰，并按幅度排序。"""
    idx = (freqs >= fmin) & (freqs <= fmax)
    f, m = freqs[idx], mag[idx]
    peaks = []
    for i in range(1, len(m) - 1):
        if m[i] > m[i-1] and m[i] >= m[i+1] and m[i] > m.max() * 0.01:
            # 抛物线插值提高频率精度
            if m[i-1] > 0 and m[i+1] > 0:
                d = 0.5 * (m[i-1] - m[i+1]) / (m[i-1] - 2*m[i] + m[i+1] + 1e-12)
            else:
                d = 0.0
            df = f[1] - f[0]
            peaks.append((f[i] + d * df, m[i]))
    peaks.sort(key=lambda p: -p[1])
    return peaks[:top]


def main():
    if not os.path.exists(WAV):
        print("找不到", WAV)
        return 1

    data, fs = read_wav(WAV)
    print("=== 文件 ===")
    print("  %s" % WAV)
    print("  采样率 %d Hz，%d 采样，%.3f 秒" % (fs, len(data), len(data)/float(fs)))

    # ============================================================
    print()
    print("=" * 62)
    print("  检验 1：单音 C4 段（0.3 ~ 1.0 秒）—— 方波谐波结构")
    print("=" * 62)

    seg = data[int(0.3*fs):int(1.0*fs)]
    freqs, mag = spectrum(seg, fs)
    peaks = find_peaks(freqs, mag)

    # 基频 = 最强峰
    f0 = peaks[0][0]
    a0 = peaks[0][1]
    print("  基频 f0 = %.2f Hz   (C4 理论值 261.63 Hz，偏差 %+.1f 音分)"
          % (f0, 1200*np.log2(f0/261.63)))
    print()
    print("  %-6s %-12s %-12s %-10s %s" % ("阶次", "理论Hz", "实测Hz", "幅度比", "判定"))
    print("  " + "-" * 56)

    odd_ok = even_ok = 0
    for k in range(1, 13):
        target = f0 * k
        if target > 6000:
            break
        # 在该谐波附近 ±2% 内找峰
        cand = [p for p in peaks if abs(p[0] - target) < target * 0.02]
        if cand:
            fpk, mpk = max(cand, key=lambda p: p[1])
            ratio = mpk / a0
        else:
            fpk, ratio = float("nan"), 0.0
        kind = "奇" if k % 2 == 1 else "偶"
        if k % 2 == 1:
            verdict = "OK" if ratio > 0.03 else "MISSING?"
            if ratio > 0.03: odd_ok += 1
        else:
            verdict = "suppressed" if ratio < 0.08 else "HIGH?"
            if ratio < 0.08: even_ok += 1
        print("  %-6s %-12.1f %-12.1f %-10.4f %s次 %s"
              % ("%df" % k, target, fpk, ratio, kind, verdict))

    print()
    print("  奇次谐波存在: %d 个    偶次谐波被抑制: %d 个" % (odd_ok, even_ok))
    if odd_ok >= 3 and even_ok >= 3:
        print("  >>> 结论：符合理想方波特征（只有奇次谐波）")
    else:
        print("  >>> 结论：谐波结构与纯方波有偏差")

    # ============================================================
    print()
    print("=" * 62)
    print("  检验 2：和弦段（1.7 ~ 2.6 秒）—— 复音独立谱峰")
    print("=" * 62)

    seg2 = data[int(1.7*fs):int(2.6*fs)]
    freqs2, mag2 = spectrum(seg2, fs)
    peaks2 = find_peaks(freqs2, mag2, top=60)

    print("  理论：C 大三和弦 = C4(261.63) + E4(329.63) + G4(392.00) Hz")
    print()
    print("  %-10s %-12s %-10s %s" % ("理论Hz", "最近实测峰", "幅度", "偏差"))
    for name, f in CHORD.items():
        cand = [p for p in peaks2 if abs(p[0] - f) < 15]
        if cand:
            fpk, mpk = max(cand, key=lambda p: p[1])
            cents = 1200*np.log2(fpk/f)
            print("  %-10.2f %-12.2f %-10.1f %+.1f 音分  <- %s"
                  % (f, fpk, mpk, cents, name))
        else:
            print("  %-10.2f %-12s %-10s %s" % (f, "未找到", "-", "<- %s 缺失!" % name))

    # 统计独立谱峰
    print()
    strong = [p for p in peaks2 if p[1] > peaks2[0][1] * 0.10]
    print("  幅度 > 10%% 最强峰的谱峰共 %d 个：" % len(strong))
    for f, m in strong[:12]:
        print("    %7.1f Hz   幅度 %7.1f" % (f, m))

    print()
    print("  >>> 结论：和弦段应出现多个独立谱峰（对应 C/E/G 及其谐波）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
