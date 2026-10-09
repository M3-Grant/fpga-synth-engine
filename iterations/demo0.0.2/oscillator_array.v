// ============================================================================
//  模块名  : oscillator_array.v
//  功能    : 振荡器阵列 —— 用 generate 例化 N 个并行声部
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)
//
//  ── 这是"复音"的关键 ───────────────────────────────────────────────
//  复音 = 多个声部同时发声。本模块把 N 份 osc_voice 并行摆开，
//  每个声部有独立的 FCW（音高）、env（包络）、gate（开关）。
//
//  ⚠ 扩复音数只需改一个参数 VOICE_NUM，不要复制粘贴代码。
//     4 → 8 → 16 → 32 都只改这一处，这是架构一次做对的意义。
//
//  ── 接口约定 ──────────────────────────────────────────────────────
//  输入数组用扁平总线传递（Verilog-2001 惯例）：
//      voice_fcw[0*32 +: 32]  = 第 0 号声部的频率控制字
//      voice_env[0*8  +: 8 ]  = 第 0 号声部的包络电平
//      voice_gate[0]          = 第 0 号声部的开关
//  测试平台和上层模块都按此约定拼接线。
//
//  作者    : 第二代迭代 1
// ============================================================================
module oscillator_array #(
    parameter VOICE_NUM  = 4,
    parameter PHASE_BITS = 32,
    parameter AMP        = 16'sh2000
)(
    input  wire                            clk,
    input  wire                            rst_n,
    input  wire                            sample_en,      // 音频采样使能
    input  wire [VOICE_NUM*PHASE_BITS-1:0] voice_fcw,      // 每声部频率控制字
    input  wire [VOICE_NUM*8-1:0]          voice_env,      // 每声部包络电平
    input  wire [VOICE_NUM-1:0]            voice_gate,     // 每声部开关
    output wire [VOICE_NUM*16-1:0]         voice_sample    // 每声部输出样本
);

    genvar i;
    generate
        for (i = 0; i < VOICE_NUM; i = i + 1) begin : gen_voice
            osc_voice #(
                .PHASE_BITS (PHASE_BITS),
                .AMP        (AMP)
            ) u_osc (
                .clk       (clk),
                .rst_n     (rst_n),
                .sample_en (sample_en),
                .fcw       (voice_fcw [i*PHASE_BITS +: PHASE_BITS]),
                .env       (voice_env [i*8 +: 8]),
                .gate      (voice_gate[i]),
                .sample    (voice_sample [i*16 +: 16])
            );
        end
    endgenerate

endmodule
