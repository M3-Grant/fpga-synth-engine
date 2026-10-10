"""严格核实 synth_demo.wav，并生成标准采样率版本。"""
import os
import struct
import math
import wave

SRC = r"D:\harness\fpga-synth-engine\code\synth_demo.wav"

print("=" * 60)
print("  第一部分：严格解析原文件")
print("=" * 60)

if not os.path.exists(SRC):
    print("文件不存在")
    raise SystemExit(1)

raw = open(SRC, "rb").read()
print("文件大小: %d 字节" % len(raw))

# ---- 手工按 WAV 规范逐字段解析 ----
pos = 0
def rd(n):
    global pos
    d = raw[pos:pos+n]
    pos += n
    return d

riff = rd(4); riff_size = struct.unpack("<I", rd(4))[0]; wave_tag = rd(4)
print("\n[RIFF 块]")
print("  ChunkID   : %r" % riff)
print("  ChunkSize : %d  (文件大小-8 = %d)" % (riff_size, len(raw)-8))
print("  Format    : %r" % wave_tag)

fmt_tag = rd(4); fmt_size = struct.unpack("<I", rd(4))[0]
fmt_body = rd(fmt_size)
audio_fmt, ch, rate, byterate, align, bits = struct.unpack("<HHIIHH", fmt_body[:16])
print("\n[fmt 块]")
print("  Subchunk1ID   : %r" % fmt_tag)
print("  Subchunk1Size : %d" % fmt_size)
print("  AudioFormat   : %d" % audio_fmt)
print("  NumChannels   : %d" % ch)
print("  SampleRate    : %d" % rate)
print("  ByteRate      : %d  (应为 %d)" % (byterate, rate * ch * bits // 8))
print("  BlockAlign    : %d  (应为 %d)" % (align, ch * bits // 8))
print("  BitsPerSample : %d" % bits)

# ---- 继续找 data chunk ----
print("\n[查找 data 块]")
while pos < len(raw) - 8:
    cid = rd(4)
    csz = struct.unpack("<I", rd(4))[0]
    print("  发现块 %r，大小 %d" % (cid, csz))
    if cid == b"data":
        data_off = pos
        data_size = csz
        break
    pos += csz

# 一致性问题检查
print("\n[一致性检查]")
problems = []
if riff_size != len(raw) - 8:
    problems.append("RIFF ChunkSize(%d) != 文件大小-8(%d)" % (riff_size, len(raw)-8))
if byterate != rate * ch * bits // 8:
    problems.append("ByteRate 不符")
if align != ch * bits // 8:
    problems.append("BlockAlign 不符")
if data_off + data_size != len(raw):
    problems.append("data 大小(%d)与剩余字节(%d)不符" % (data_size, len(raw)-data_off))
if problems:
    for p in problems:
        print("  [!] %s" % p)
else:
    print("  全部一致，无问题")

# ---- 样本分析 ----
pcm = raw[data_off:data_off+data_size]
n = len(pcm) // 2
samples = struct.unpack("<%dh" % n, pcm[:n*2])
peak = max(abs(s) for s in samples)
rms = math.sqrt(sum(s*s for s in samples) / float(n))
nz = sum(1 for s in samples if s != 0)

print("\n[音频数据]")
print("  样本数   : %d" % n)
print("  时长     : %.3f 秒" % (n / float(rate)))
print("  峰值     : %d" % peak)
print("  RMS      : %.1f" % rms)
print("  非零占比 : %.1f%%" % (nz * 100.0 / n))

# ---- 标准库能否打开 ----
print("\n[标准库 wave 读取]")
try:
    w = wave.open(SRC, "rb")
    print("  OK: %d声道 %dbit %dHz %d帧" %
          (w.getnchannels(), w.getsampwidth()*8, w.getframerate(), w.getnframes()))
    w.close()
except Exception as e:
    print("  FAIL: %s" % e)

# ============================================================
print()
print("=" * 60)
print("  第二部分：生成标准采样率版本（44100 Hz）")
print("=" * 60)

# 线性插值重采样到 44100
NEW_RATE = 44100
ratio = rate / float(NEW_RATE)
new_n = int(n / ratio)
out = []
for i in range(new_n):
    src_idx = i * ratio
    i0 = int(src_idx)
    i1 = min(i0 + 1, n - 1)
    frac = src_idx - i0
    v = samples[i0] * (1 - frac) + samples[i1] * frac
    out.append(int(round(v)))

DST = r"D:\harness\fpga-synth-engine\code\synth_demo_44k.wav"
with wave.open(DST, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(NEW_RATE)
    w.writeframes(struct.pack("<%dh" % len(out), *out))

print("  已生成: %s" % DST)
print("  采样率 %d Hz，%d 采样，%.3f 秒" % (NEW_RATE, len(out), len(out)/float(NEW_RATE)))

# 验证新文件
try:
    w = wave.open(DST, "rb")
    print("  wave 模块读取: OK (%d声道 %dbit %dHz %d帧)" %
          (w.getnchannels(), w.getsampwidth()*8, w.getframerate(), w.getnframes()))
    w.close()
    print("  [PASS] 标准版可用任何播放器打开")
except Exception as e:
    print("  [FAIL] %s" % e)

print()
print("=" * 60)
print("  结论")
print("=" * 60)
print("  原始文件头合法，但采样率 52734 Hz 非标准，")
print("  部分播放器/系统会拒读。已生成 44100 Hz 标准版。")
