"""验证 synth_demo.wav 是否合法、分析音频内容。"""
import os
import struct
import math
import wave

PATH = r"D:\harness\fpga-synth-engine\code\synth_demo.wav"

if not os.path.exists(PATH):
    print("文件不存在:", PATH)
    raise SystemExit(1)

size = os.path.getsize(PATH)
print("=== 文件 ===")
print("  路径 : %s" % PATH)
print("  大小 : %d 字节 (%.1f KB)" % (size, size / 1024.0))

# ---- 手工解析 WAV 头 ----
with open(PATH, "rb") as f:
    raw = f.read()

riff = raw[0:4]
wave_tag = raw[8:12]
fmt  = raw[12:16]
data_tag = raw[36:40]
audio_fmt, channels, rate, byterate, align, bits = struct.unpack("<HHIIHH", raw[20:36])

print()
print("=== 头信息 ===")
print("  RIFF 标记 : %s" % riff.decode("ascii", "replace"))
print("  WAVE 标记 : %s" % wave_tag.decode("ascii", "replace"))
print("  fmt  标记 : %s" % fmt.decode("ascii", "replace"))
print("  data 标记 : %s" % data_tag.decode("ascii", "replace"))
print("  格式      : %d (1=PCM)" % audio_fmt)
print("  声道      : %d" % channels)
print("  采样率    : %d Hz" % rate)
print("  字节率    : %d" % byterate)
print("  块对齐    : %d" % align)
print("  位深      : %d bit" % bits)

ok_header = (riff == b"RIFF" and wave_tag == b"WAVE" and fmt == b"fmt "
             and data_tag == b"data" and audio_fmt == 1)
print("  头是否合法: %s" % ("是" if ok_header else "否"))

# ---- 解析音频数据 ----
pcm = raw[44:]
n = len(pcm) // 2
samples = struct.unpack("<%dh" % n, pcm[:n*2])

peak = max(abs(s) for s in samples)
rms = math.sqrt(sum(s * s for s in samples) / float(n))
nonzero = sum(1 for s in samples if s != 0)

print()
print("=== 音频数据 ===")
print("  采样数    : %d" % n)
print("  时长      : %.3f 秒" % (n / float(rate)))
print("  峰值      : %d  (满量程 32767)" % peak)
print("  RMS       : %.1f" % rms)
print("  非零采样  : %d / %d (%.1f%%)" % (nonzero, n, nonzero * 100.0 / n))

# ---- 用标准库再验一次 ----
print()
print("=== 标准库校验 ===")
try:
    w = wave.open(PATH, "rb")
    print("  wave 模块读取成功:")
    print("    声道 %d, %d bit, %d Hz, %d 帧" %
          (w.getnchannels(), w.getsampwidth() * 8, w.getframerate(), w.getnframes()))
    w.close()
    print("  [PASS] 文件可被标准库正确解析")
except Exception as e:
    print("  [FAIL] %s" % e)

print()
if ok_header and peak > 100 and nonzero > n * 0.3:
    print(">>> 结论: WAV 文件有效，可以直接用播放器打开")
else:
    print(">>> 结论: 数据异常，需要检查")
