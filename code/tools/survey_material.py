#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
批量分析一批视频提取出的 WAV，输出"素材总览"：
时长、峰值、主要音高、有声/静音分段。

用法：
    python tools/survey_material.py <目录>
"""
import os
import sys
import glob
import numpy as np
from scipy.io import wavfile

NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']


def hz_to_note(f):
    if f < 30:
        return '-'
    n = 12 * np.log2(f / 261.63)
    octv = 4 + int(np.floor(n / 12))
    semi = int(round(n - np.floor(n / 12) * 12)) % 12
    return '%s%d' % (NAMES[semi], octv)


def analyze(path):
    fs, d = wavfile.read(path)
    x = d.astype(np.float64)
    if x.ndim > 1:
        x = x.mean(axis=1)
    x = x / 32768.0
    dur = len(x) / fs
    peak = float(np.max(np.abs(x))) if len(x) else 0.0
    rms = float(np.sqrt(np.mean(x ** 2))) if len(x) else 0.0

    # 主要频率
    n = min(len(x), 32768)
    w = np.hanning(n)
    seg = (x[:n] - x[:n].mean()) * w
    spec = np.abs(np.fft.rfft(seg, 32768)) * 2 / w.sum()
    freqs = np.fft.rfftfreq(32768, 1.0 / fs)
    ref = spec.max() if spec.max() > 0 else 1
    idx = [i for i in range(2, len(spec) - 1)
           if spec[i] > spec[i - 1] and spec[i] >= spec[i + 1]]
    idx.sort(key=lambda i: spec[i], reverse=True)
    peaks = []
    used = []
    for i in idx:
        f = freqs[i]
        if any(abs(f - u) < 20 for u in used):
            continue
        used.append(f)
        peaks.append((f, 20 * np.log10(max(spec[i], 1e-12) / ref)))
        if len(peaks) >= 5:
            break

    # 音高：取 < 1kHz 的最低显著峰
    low = [p for p in peaks if 30 < p[0] < 1000]
    note = '-'
    if low:
        f0 = min(low, key=lambda t: t[0])[0]
        note = '%s (%.1f Hz)' % (hz_to_note(f0), f0)

    # 有声/静音段（0.5s 分辨率）
    win = int(0.5 * fs)
    segs = []
    thr = max(rms * 0.7, 1e-4)
    for k in range(len(x) // win):
        r = np.sqrt(np.mean(x[k * win:(k + 1) * win] ** 2))
        segs.append('#' if r > thr else '.')

    return {
        'dur': dur, 'peak': peak, 'rms': rms,
        'peaks': peaks, 'note': note, 'segs': ''.join(segs),
    }


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else '.'
    files = sorted(glob.glob(os.path.join(d, 'DSC_*.wav')))
    if not files:
        print('no WAV found in ' + d)
        return 1

    print('=' * 78)
    print('  素材总览')
    print('=' * 78)
    for f in files:
        r = analyze(f)
        name = os.path.basename(f)
        print('\n【%s】  时长 %.1f s   峰值 %.3f   RMS %.1f dBFS'
              % (name, r['dur'], r['peak'], 20 * np.log10(max(r['rms'], 1e-9))))
        print('  音高估计: %s' % r['note'])
        print('  主要频率: ' + ', '.join('%.0fHz(%.0fdB)' % (fr, db) for fr, db in r['peaks'][:4]))
        print('  有声分布(#)/静音(.) 每格0.5s:')
        s = r['segs']
        for i in range(0, len(s), 60):
            print('    ' + s[i:i + 60])
    print('\n' + '=' * 78)
    return 0


if __name__ == '__main__':
    sys.exit(main())
