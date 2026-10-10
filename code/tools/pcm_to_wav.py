"""把仿真导出的原始 PCM 数据封装成标准 WAV 文件。

背景：
    iverilog 的 $fwrite 只能顺序写文件，无法回填 RIFF/data 块的大小字段，
    导致之前生成的 WAV 里 ChunkSize 和 data size 都是 0，播放器无法读取。
    因此改为：iverilog 只写原始 PCM，本脚本封装 WAV 头（能正确回填大小）。

用法：
    python pcm_to_wav.py                         # 默认 52734 Hz（原始采样率）
    python pcm_to_wav.py --rate 44100            # 转成标准采样率
"""
import os
import struct
import wave
import math
import sys

BASE = r"D:\harness\fpga-synth-engine\code"
PCM  = os.path.join(BASE, "synth_demo.pcm")
SRC_RATE = 52734          # FPGA 实际采样率


def main():
    rate = SRC_RATE
    if "--rate" in sys.argv:
        rate = int(sys.argv[sys.argv.index("--rate") + 1])

    if not os.path.exists(PCM):
        print("[错误] 找不到 %s" % PCM)
        print("       请先运行 tb_export_wav.v 生成原始 PCM")
        return 1

    raw = open(PCM, "rb").read()
    n = len(raw) // 2
    samples = struct.unpack("<%dh" % n, raw[:n * 2])

    peak = max(abs(s) for s in samples) if n else 0
    rms = math.sqrt(sum(s * s for s in samples) / float(n)) if n else 0.0
    nz = sum(1 for s in samples if s != 0)

    print("=== 原始 PCM ===")
    print("  文件   : %s" % PCM)
    print("  字节   : %d" % len(raw))
    print("  采样数 : %d" % n)
    print("  原始采样率: %d Hz" % SRC_RATE)
    print("  峰值   : %d" % peak)
    print("  RMS    : %.1f" % rms)
    print("  非零占比: %.1f%%" % (nz * 100.0 / n if n else 0))

    # ---- 需要重采样？ ----
    if rate != SRC_RATE:
        ratio = SRC_RATE / float(rate)
        new_n = int(n / ratio)
        out = []
        for i in range(new_n):
            si = i * ratio
            i0 = int(si)
            i1 = min(i0 + 1, n - 1)
            f = si - i0
            out.append(int(round(samples[i0] * (1 - f) + samples[i1] * f)))
        samples = out
        n = len(samples)
        print("\n  已重采样到 %d Hz，%d 采样" % (rate, n))

    # ---- 写标准 WAV（wave 模块会自动回填所有大小字段）----
    dst = os.path.join(BASE, "synth_demo.wav" if rate == SRC_RATE else "synth_demo_%dk.wav" % (rate // 1000))
    with wave.open(dst, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack("<%dh" % n, *samples))

    print("\n=== 已生成标准 WAV ===")
    print("  文件   : %s" % dst)
    print("  大小   : %d 字节" % os.path.getsize(dst))
    print("  时长   : %.3f 秒" % (n / float(rate)))

    # ---- 回读验证（这一步能确认大小字段正确）----
    print("\n=== 回读验证 ===")
    try:
        with wave.open(dst, "rb") as w:
            print("  声道   : %d" % w.getnchannels())
            print("  位深   : %d bit" % (w.getsampwidth() * 8))
            print("  采样率 : %d Hz" % w.getframerate())
            print("  帧数   : %d" % w.getnframes())
        # 手工核对大小字段
        h = open(dst, "rb").read(44)
        riff_size = struct.unpack("<I", h[4:8])[0]
        data_size = struct.unpack("<I", h[40:44])[0]
        fsize = os.path.getsize(dst)
        print("  RIFF ChunkSize : %d  (文件大小-8 = %d)  %s" %
              (riff_size, fsize - 8, "OK" if riff_size == fsize - 8 else "不符"))
        print("  data 块大小    : %d  (应为 %d)  %s" %
              (data_size, fsize - 44, "OK" if data_size == fsize - 44 else "不符"))
        if riff_size == fsize - 8 and data_size == fsize - 44:
            print("\n  [PASS] 标准 WAV，任何播放器都能打开")
        else:
            print("\n  [FAIL] 大小字段仍不正确")
    except Exception as e:
        print("  [FAIL] %s" % e)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
