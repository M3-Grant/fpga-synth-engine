#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
从视频文件里提取音频到 WAV（用 PyAV，不需要 ffmpeg 命令行）。

用法：
    python tools/extract_audio.py <video> [out.wav] [--max-seconds N]
"""
import sys
import wave
import numpy as np


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith('--') else src.rsplit('.', 1)[0] + '.wav'
    max_sec = None
    for a in sys.argv[2:]:
        if a.startswith('--max-seconds'):
            try:
                max_sec = float(a.split('=')[1])
            except Exception:
                pass

    import av
    container = av.open(src)
    astream = None
    for s in container.streams:
        if s.type == 'audio':
            astream = s
            break
    if astream is None:
        print("no audio stream found")
        return 1

    fs = astream.rate
    print("audio stream: %d Hz, channels=%s" % (fs, astream.channels))
    print("container duration: %.1f s" % (float(container.duration) / av.time_base) if container.duration else "duration unknown")

    chunks = []
    total = 0
    for frame in container.decode(astream):
        arr = frame.to_ndarray()
        if arr.ndim == 2:
            if arr.shape[0] > 1:
                arr = arr.mean(axis=0)
            else:
                arr = arr[0]
        arr = arr.astype(np.float32)
        chunks.append(arr)
        total += len(arr)
        if max_sec and total / fs > max_sec:
            break

    x = np.concatenate(chunks) if chunks else np.zeros(1)
    peak = float(np.max(np.abs(x))) if len(x) else 0.0
    print("decoded: %.1f s, peak=%.3f" % (len(x) / fs, peak))

    # 归一化到 16 位
    scale = 1.0
    if peak > 1.0:
        scale = 32767.0 / peak
    pcm = np.clip(x * scale, -1.0, 1.0)
    pcm16 = np.round(pcm * 32767).astype('<i2')

    with wave.open(out, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(fs)
        w.writeframes(pcm16.tobytes())

    print("saved: %s  (%.1f MB)" % (out, len(pcm16) * 2 / 1024 / 1024))
    return 0


if __name__ == '__main__':
    sys.exit(main())
