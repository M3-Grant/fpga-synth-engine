"""把仿真导出的十六进制样本文本转成标准 WAV 文件。

背景与踩坑记录：
    最初让 iverilog 直接写 WAV 文件，遇到两个问题：
      1) RIFF ChunkSize / data 块大小无法回填（$fwrite 只能顺序写）
         → 播放器不知道数据长度，拒读
      2) 改用 $fwrite("%c") 写二进制 PCM 后，iverilog 把 NUL 字节(0x00)
         当字符串终止符，而音频样本低字节常为 0x00
         → 数据在第一个 0x00 处截断，时长显示 0、只听到极短一段

    最终方案：iverilog 只导出**十六进制文本**（每行一个 16 位样本），
              由本脚本解析并封装标准 WAV。彻底避开二进制写入问题。

输入：synth_demo.hex   每行 4 位十六进制（16 位有符号样本补码）
输出：synth_demo.wav        原始采样率 52734 Hz
      synth_demo_44k.wav   44100 Hz（可选，兼容性最好）

用法：
    python hex_to_wav.py
    python hex_to_wav.py --rate 44100
"""
import os
import struct
import wave
import math
import sys

BASE = r"D:\harness\fpga-synth-engine\code"
HEX  = os.path.join(BASE, "synth_demo.hex")
SRC_RATE = 52734          # FPGA 实际采样率 = 27MHz / 8 / 64


def load_samples(path):
    """解析十六进制文本，返回有符号 16 位样本列表。"""
    vals = []
    bad = 0
    with open(path, "r") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            try:
                v = int(s, 16)
            except ValueError:
                bad += 1
                continue
            # 转成有符号 16 位
            if v >= 0x8000:
                v -= 0x10000
            vals.append(v)
    if bad:
        print("  警告: 跳过 %d 行无法解析的内容" % bad)
    return vals


def main():
    rate = SRC_RATE
    if "--rate" in sys.argv:
        rate = int(sys.argv[sys.argv.index("--rate") + 1])

    if not os.path.exists(HEX):
        print("[错误] 找不到 %s" % HEX)
        print("       请先运行 tb_export_wav.v 生成十六进制样本")
        return 1

    print("=== 读取十六进制样本 ===")
    print("  文件   : %s" % HEX)
    print("  大小   : %d 字节" % os.path.getsize(HEX))

    samples = load_samples(HEX)
    n = len(samples)
    if n == 0:
        print("[错误] 没有解析到任何样本")
        return 1

    peak = max(abs(s) for s in samples)
    rms = math.sqrt(sum(s * s for s in samples) / float(n))
    nz = sum(1 for s in samples if s != 0)

    print("  采样数 : %d" % n)
    print("  时长   : %.3f 秒 @ %d Hz" % (n / float(SRC_RATE), SRC_RATE))
    print("  峰值   : %d" % peak)
    print("  RMS    : %.1f" % rms)
    print("  非零占比: %.1f%%" % (nz * 100.0 / n))

    # 前几个样本，便于人工核对
    print("  前 8 个样本: %s" % samples[:8])

    # ---- 重采样 ----
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

    # ---- 写标准 WAV ----
    dst = os.path.join(BASE, "synth_demo.wav" if rate == SRC_RATE
                             else "synth_demo_%dk.wav" % (rate // 1000))
    with wave.open(dst, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack("<%dh" % n, *samples))

    print("\n=== 已生成 WAV ===")
    print("  文件   : %s" % dst)
    print("  大小   : %d 字节" % os.path.getsize(dst))
    print("  时长   : %.3f 秒" % (n / float(rate)))

    # ---- 回读验证 ----
    print("\n=== 回读验证 ===")
    try:
        with wave.open(dst, "rb") as w:
            print("  声道   : %d" % w.getnchannels())
            print("  位深   : %d bit" % (w.getsampwidth() * 8))
            print("  采样率 : %d Hz" % w.getframerate())
            print("  帧数   : %d" % w.getnframes())
            frames = w.readframes(w.getnframes())
        back = struct.unpack("<%dh" % (len(frames) // 2), frames)
        print("  回读采样数: %d" % len(back))
        print("  与写入一致: %s" % ("是" if len(back) == n else "否"))

        h = open(dst, "rb").read(44)
        riff_size = struct.unpack("<I", h[4:8])[0]
        data_size = struct.unpack("<I", h[40:44])[0]
        fsize = os.path.getsize(dst)
        ok1 = riff_size == fsize - 8
        ok2 = data_size == fsize - 44
        print("  RIFF ChunkSize : %d  %s" % (riff_size, "OK" if ok1 else "不符"))
        print("  data 块大小    : %d  %s" % (data_size, "OK" if ok2 else "不符"))
        if ok1 and ok2 and len(back) == n and peak > 0:
            print("\n  [PASS] 标准 WAV，可正常播放")
        else:
            print("\n  [FAIL] 有问题，需检查")
    except Exception as e:
        print("  [FAIL] %s" % e)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
