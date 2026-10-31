#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
用电脑麦克风录音并立即做频谱分析。

关键点：提供多个设备（含 WASAPI / WDM-KS）入口，方便绕过系统的"麦克风增强/AGC"。

用法：
    python tools/record_mic.py <device_index> <seconds> <out.wav>

找不到合适设备时先跑 `python tools/record_mic.py list` 看设备表。
"""
import sys
import numpy as np


def list_devices():
    import sounddevice as sd
    print(sd.query_devices())


def record(dev, secs, path, fs=48000):
    import sounddevice as sd
    import wave
    print("recording %.1f s on device %s ..." % (secs, dev))
    rec = sd.rec(int(secs * fs), samplerate=fs, channels=1, device=dev, dtype='float32')
    sd.wait()
    x = rec[:, 0].astype(np.float64)
    peak = float(np.max(np.abs(x))) if len(x) else 0.0
    print("peak = %.5f  (%.1f dBFS)" % (peak, 20*np.log10(max(peak, 1e-9))))

    pcm = np.clip(np.round(x * 32767), -32768, 32767).astype('<i2')
    with wave.open(path, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(fs)
        w.writeframes(pcm.tobytes())
    print("saved:", path)
    return x, fs


def analyze(x, fs, label=""):
    n = min(len(x), 16384)
    w = np.hanning(n)
    seg = (x[:n] - np.mean(x[:n])) * w
    spec = np.abs(np.fft.rfft(seg, 16384)) * 2 / w.sum()
    f = np.fft.rfftfreq(16384, 1.0 / fs)
    ref = float(np.max(spec))

    print("\n-- %s 最强 10 个成分 --" % label)
    idx = [i for i in range(1, len(spec)-1) if spec[i] > spec[i-1] and spec[i] >= spec[i+1]]
    idx.sort(key=lambda i: spec[i], reverse=True)
    used = []
    shown = 0
    for i in idx:
        if any(abs(f[i]-u) < 25 for u in used):
            continue
        used.append(f[i])
        print("  %9.1f Hz   %10.6f   %7.1f dB" % (f[i], spec[i], 20*np.log10(max(spec[i],1e-12)/max(ref,1e-12))))
        shown += 1
        if shown >= 10:
            break

    def at(freq, tol=15):
        m = np.abs(f - freq) <= tol
        return float(np.max(spec[m])) if np.any(m) else 0.0

    print("\n  关键频点：")
    for lab, fr in [("220 Hz (若播放速率减半)", 220.0),
                    ("440 Hz (tone_test 期望)", 440.0),
                    ("880 Hz", 880.0),
                    ("9419 Hz (440x21.4)", 9419.0),
                    ("10007 Hz (之前最强)", 10007.0)]:
        print("    %-26s %10.6f  %7.1f dB" % (lab, at(fr), 20*np.log10(max(at(fr),1e-12)/max(ref,1e-12))))

    floor = float(np.median(spec))
    print("\n  噪声底(中位): %.3e  (%.1f dB)" % (floor, 20*np.log10(max(floor,1e-12)/max(ref,1e-12))))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    if sys.argv[1] == 'list':
        list_devices()
        return 0

    dev = int(sys.argv[1])
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 6.0
    out = sys.argv[3] if len(sys.argv) > 3 else 'mic_rec.wav'

    x, fs = record(dev, secs, out)
    analyze(x, fs, "整体")
    return 0


if __name__ == "__main__":
    sys.exit(main())
