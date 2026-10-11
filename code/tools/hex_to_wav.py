"""把仿真导出的十六进制样本文本转成标准 WAV 文件。

背景与踩坑记录：
    最初让 iverilog 直接写 WAV，遇到两个问题：
      1) RIFF ChunkSize / data 块大小无法回填（$fwrite 只能顺序写）
         → 播放器不知道数据长度，拒读
      2) 改用 $fwrite("%c") 写二进制 PCM 后，iverilog 把 NUL 字节(0x00)
         当字符串终止符，而音频样本低字节常为 0x00
         → 数据在第一个 0x00 处截断，时长显示 0、只听到极短一段

    最终方案：iverilog 只导出**十六进制文本**（每行一个 16 位样本），
              由本脚本解析并封装标准 WAV。彻底避开二进制写入问题。

关于循环拼接：
    iverilog 是解释执行，仿真很慢（约 37000 采样/分钟）。
    要得到 7 秒音频（约 370000 采样）需仿真 10 分钟以上。
    因此支持 --loop N：把较短的真实演奏循环拼接，并在接缝处做
    交叉淡入淡出，避免爆音。听感上比等长仿真划算得多。

输入：synth_demo.hex   每行 4 位十六进制（16 位有符号样本补码）
输出：synth_demo.wav        原始采样率 52734 Hz
      synth_demo_44k.wav   44100 Hz（可选）

用法：
    python hex_to_wav.py                          # 原速，不循环
    python hex_to_wav.py --loop 2                 # 循环 2 次
    python hex_to_wav.py --loop 2 --rate 44100    # 循环 + 重采样
    python hex_to_wav.py --xfade 15               # 接缝交叉淡化 15ms
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
            if v >= 0x8000:          # 转有符号
                v -= 0x10000
            vals.append(v)
    if bad:
        print("  警告: 跳过 %d 行无法解析的内容" % bad)
    return vals


def loop_with_xfade(samples, times, xfade_n):
    """把样本循环 times 次，接缝处做交叉淡入淡出。

    原理：前一段末尾 xfade_n 个样本逐渐减弱，后一段开头同样长度逐渐增强，
    两者叠加。这样接缝处能量连续，不会有"咔"的一声。
    """
    if times <= 1:
        return samples

    n = len(samples)
    if xfade_n <= 0 or xfade_n * 2 >= n:
        # 不做淡化，直接拼接
        return samples * times

    out = samples[:n - xfade_n]          # 第一段去掉尾部（留作交叠）
    for t in range(1, times):
        seg = samples[:]
        # 与上一段尾部交叠
        tail = out[-xfade_n:]
        for i in range(xfade_n):
            f_out = (xfade_n - i) / float(xfade_n)   # 上一段渐弱
            f_in = i / float(xfade_n)                # 新段渐强
            seg[i] = int(round(tail[i] * f_out + seg[i] * f_in))
        # 最后一段保留完整的尾部
        if t == times - 1:
            out.extend(seg)
        else:
            out.extend(seg[:n - xfade_n])
    return out


def main():
    rate = SRC_RATE
    loop = 1
    xfade_ms = 15

    if "--rate" in sys.argv:
        rate = int(sys.argv[sys.argv.index("--rate") + 1])
    if "--loop" in sys.argv:
        loop = int(sys.argv[sys.argv.index("--loop") + 1])
    if "--xfade" in sys.argv:
        xfade_ms = int(sys.argv[sys.argv.index("--xfade") + 1])

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
    print("  前 8 个样本: %s" % samples[:8])

    # ---- 循环拼接 ----
    if loop > 1:
        xfade_n = int(SRC_RATE * xfade_ms / 1000.0)
        print("\n=== 循环拼接 ===")
        print("  循环次数 : %d" % loop)
        print("  接缝淡化 : %d ms (%d 采样)" % (xfade_ms, xfade_n))
        samples = loop_with_xfade(samples, loop, xfade_n)
        n = len(samples)
        print("  拼接后   : %d 采样，%.3f 秒" % (n, n / float(SRC_RATE)))
        peak = max(abs(s) for s in samples)

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
    if rate == SRC_RATE:
        dst = os.path.join(BASE, "synth_demo.wav")
    else:
        dst = os.path.join(BASE, "synth_demo_%dk.wav" % (rate // 1000))

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
            ch = w.getnchannels()
            sw = w.getsampwidth()
            fr = w.getframerate()
            nf = w.getnframes()
            frames = w.readframes(nf)
        back = struct.unpack("<%dh" % (len(frames) // 2), frames)
        print("  声道/位深/采样率: %dch %dbit %dHz" % (ch, sw * 8, fr))
        print("  帧数           : %d" % nf)
        print("  回读采样数     : %d" % len(back))
        print("  与写入一致     : %s" % ("是" if len(back) == n else "否"))

        h = open(dst, "rb").read(44)
        riff_size = struct.unpack("<I", h[4:8])[0]
        data_size = struct.unpack("<I", h[40:44])[0]
        fsize = os.path.getsize(dst)
        ok1 = riff_size == fsize - 8
        ok2 = data_size == fsize - 44
        print("  RIFF ChunkSize : %d  %s" % (riff_size, "OK" if ok1 else "不符"))
        print("  data 块大小    : %d  %s" % (data_size, "OK" if ok2 else "不符"))

        if ok1 and ok2 and len(back) == n and peak > 0:
            print("\n  [PASS] 标准 WAV，可正常播放，时长 %.2f 秒" % (nf / float(fr)))
        else:
            print("\n  [FAIL] 有问题，需检查")
    except Exception as e:
        print("  [FAIL] %s" % e)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
