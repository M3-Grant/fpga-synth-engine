#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
把 tb_piano_wav.v 导出的 piano_2s.txt 转成 WAV，方便直接试听。

输入：code/piano_2s.txt     每行一个十进制样本（16 位有符号）
输出：code/piano_2s.wav     原始采样率 52734 Hz（音高最准确）
      code/piano_2s_44k.wav 重采样到 44100 Hz（兼容性最好）

用法：C:\\Python314\\python.exe tools\\txt_to_wav.py
"""
import os
import sys
import wave

import numpy as np

FS = 52734          # 实际是 52734.375，取整误差 0.0007%，听不出来


def write_wav(path, data, fs):
    data = np.clip(np.round(data), -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(fs)
        w.writeframes(data.tobytes())


def main():
    base = os.path.dirname(os.path.abspath(__file__))
    cand = [
        os.path.join(base, "..", "piano_2s.txt"),
        os.path.join(base, "..", "..", "code", "piano_2s.txt"),
        "piano_2s.txt",
    ]
    src = next((p for p in cand if os.path.exists(p)), None)
    if src is None:
        print("[ERROR] 找不到 piano_2s.txt，先跑 tb_piano_wav")
        return 2

    x = np.loadtxt(src)
    out_dir = os.path.dirname(os.path.abspath(src))
    peak = float(np.max(np.abs(x)))

    print("=" * 58)
    print("  钢琴音试听导出")
    print("=" * 58)
    print("输入样本   : %d  (%.3f s @ %d Hz)" % (len(x), len(x) / FS, FS))
    print("峰值       : %d / 32767  (%.1f%% 满量程)" % (peak, peak / 32767 * 100))
    rms = float(np.sqrt(np.mean(x ** 2)))
    print("RMS        : %.0f  (%.1f dBFS)" % (rms, 20 * np.log10(max(rms, 1) / 32767)))

    p1 = os.path.join(out_dir, "piano_2s.wav")
    write_wav(p1, x, FS)
    print("\n已写出 : %s  (%d Hz)" % (p1, FS))

    # 重采样到 44100，兼容性更好（音高不变）
    try:
        from scipy.signal import resample_poly
        y = resample_poly(x.astype(np.float64), 44100, FS)
        p2 = os.path.join(out_dir, "piano_2s_44k.wav")
        write_wav(p2, y, 44100)
        print("已写出 : %s  (44100 Hz, %d 样本)" % (p2, len(y)))
    except Exception as e:
        print("[WARN] 重采样失败（%s），只保留原始版本" % e)

    print("=" * 58)
    return 0


if __name__ == "__main__":
    sys.exit(main())
