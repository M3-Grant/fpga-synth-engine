#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_fcw.py —— 生成 DDS 频率控制字（FCW）查找表

为什么必须按"实际采样率"算：
    DDS 输出频率 f = FCW * fs / 2^32
    如果 FCW 是按 48000 算的，而板子实际跑 52734 Hz，
    弹出来的 A4 会是 483 Hz（跑调 20 多个半音）。
    所以 FCW 必须跟 i2s_tx 的实际 fs 严格对应。

用法：
    python gen_fcw.py 27e6 4        # 主时钟 27MHz，BCK_HALF=4
    python gen_fcw.py 27e6 4 --out note_table.v
"""

import sys
import math

# ---------------------------------------------------------------- 参数
N_ACC = 32                       # 相位累加器位宽
SLOT_BCK = 32                    # 每个声道占 32 个 BCK（I2S 32bit 帧）
SCALE = 2 ** N_ACC


def compute_fs(clk_hz: float, bck_half: int) -> float:
    """fs = clk / (2*BCK_HALF) / (2*SLOT_BCK)"""
    bck = clk_hz / (2.0 * bck_half)
    return bck / (2.0 * SLOT_BCK)


def fcw(freq_hz: float, fs: float) -> int:
    return int(round(freq_hz * SCALE / fs))


NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def midi_to_freq(m: int) -> float:
    """MIDI 音高 -> 频率（A4=69=440Hz）"""
    return 440.0 * (2.0 ** ((m - 69) / 12.0))


def note_name(m: int) -> str:
    return f"{NOTE_NAMES[m % 12]}{m // 12 - 1}"


def main():
    clk_hz = float(sys.argv[1]) if len(sys.argv) > 1 else 27e6
    bck_half = int(sys.argv[2]) if len(sys.argv) > 2 else 4

    fs = compute_fs(clk_hz, bck_half)
    print(f"主时钟 clk     = {clk_hz/1e6:.3f} MHz")
    print(f"BCK_HALF      = {bck_half}")
    print(f"BCK           = {clk_hz/(2.0*bck_half)/1e6:.4f} MHz")
    print(f"实际采样率 fs  = {fs:.3f} Hz")
    print(f"频率分辨率     = {fs/SCALE:.6f} Hz")
    print()

    lo, hi = 60, 84          # C4 ~ C6，共 25 个半音（2 个八度 + 1）
    lines = []
    for m in range(lo, hi + 1):
        f = midi_to_freq(m)
        w = fcw(f, fs)
        real = w * fs / SCALE
        err = (real - f) / f * 100.0
        lines.append((m, note_name(m), f, w, real, err))

    print(f"{'MIDI':>4} {'音名':>4} {'目标Hz':>10} {'FCW':>12} {'实际Hz':>10} {'误差%':>8}")
    for m, n, f, w, real, err in lines:
        print(f"{m:>4} {n:>4} {f:>10.3f} {w:>12d} {real:>10.3f} {err:>8.4f}")

    # ---- 输出 Verilog 查找表 ----
    out = "note_table.v"
    if "--out" in sys.argv:
        out = sys.argv[sys.argv.index("--out") + 1]

    with open(out, "w", encoding="utf-8") as fp:
        fp.write("// ============================================================\n")
        fp.write("//  note_table.v —— 音符 → 频率控制字（FCW）查找表\n")
        fp.write("//  自动生成，请勿手改。重新生成：python gen_fcw.py 27e6 4 --out note_table.v\n")
        fp.write("//\n")
        fp.write(f"//  主时钟   : {clk_hz/1e6:.3f} MHz\n")
        fp.write(f"//  BCK_HALF : {bck_half}\n")
        fp.write(f"//  实际 fs  : {fs:.3f} Hz\n")
        fp.write(f"//  公式     : FCW = f * 2^32 / fs\n")
        fp.write("// ============================================================\n\n")
        fp.write("module note_table (\n")
        fp.write("    input  wire [4:0]  note_idx,   // 0..24 -> MIDI %d..%d\n" % (lo, hi))
        fp.write("    output reg  [31:0] fcw\n")
        fp.write(");\n\n")
        fp.write("    always @(*) begin\n")
        fp.write("        case (note_idx)\n")
        for i, (m, n, f, w, _r, _e) in enumerate(lines):
            fp.write(f"            5'd{i:<2d}: fcw = 32'd{w};  // {n} ({f:.2f} Hz)\n")
        fp.write("            default: fcw = 32'd0;\n")
        fp.write("        endcase\n")
        fp.write("    end\n\n")
        fp.write("endmodule\n")
    print(f"\n已生成：{out}")


if __name__ == "__main__":
    main()
