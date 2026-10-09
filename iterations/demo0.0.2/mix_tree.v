// ============================================================================
//  模块名  : mix_tree.v
//  功能    : 混音器 —— 把 N 个声部的样本相加，并做饱和处理防止削波失真
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)
//
//  ── 为什么需要饱和而不是直接截断 ──────────────────────────────────
//  N 个声部相加会溢出。如果直接让高位溢出回绕（wrap around），
//  声音会从最大正数瞬间跳到最大负数，产生刺耳的"爆音"。
//  正确做法是饱和（saturation）：超过上限就钳位在上限。
//
//  ── 位宽设计 ──────────────────────────────────────────────────────
//  输入：VOICE_NUM 个 IN_BITS 位有符号样本
//  SUM_BITS = IN_BITS + log2(VOICE_NUM) + 2   额外留 2 位余量
//  OUT_BITS = 20（迭代 1 固定），可在外层裁剪
//
//  ⚠ 实现注意：饱和边界用「显式位宽的常量」而不是移位表达式。
//     早期版本用 localparam signed + (1 <<< (OUT_BITS-1))，
//     iverilog 下综合出 X（未定义值），导致整个通路输出 X。
//     改成直接写常量后正常。
//
//  作者    : 第二代迭代 1
// ============================================================================
module mix_tree #(
    parameter VOICE_NUM = 4,
    parameter IN_BITS   = 16,       // 每个声部的位宽（有符号）
    parameter OUT_BITS  = 20        // 输出位宽
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          sample_en,    // 采样使能（单周期脉冲）
    input  wire [VOICE_NUM*IN_BITS-1:0]  samples_in,   // 各声部样本
    output reg  signed [OUT_BITS-1:0]    mix_out       // 混音输出（已饱和）
);

    localparam SUM_BITS = IN_BITS + 4;   // 16+4=20 位，4 声部最多用 18 位，够

    // ------------------------------------------------------------------
    // 1. 求和：逐个符号扩展后累加
    //    SUM_BITS 足够宽，4 声部 × 8192 = 32768，20 位能表达 ±524288
    // ------------------------------------------------------------------
    reg signed [SUM_BITS-1:0] sum;

    integer i;
    always @(*) begin
        sum = {SUM_BITS{1'b0}};
        for (i = 0; i < VOICE_NUM; i = i + 1) begin
            sum = sum + $signed(samples_in[i*IN_BITS +: IN_BITS]);
        end
    end

    // ------------------------------------------------------------------
    // 2. 饱和：显式常量边界，避免移位表达式的歧义
    //    OUT_BITS=20 时，范围是 -524288 ~ +524287
    // ------------------------------------------------------------------
    reg signed [OUT_BITS-1:0] sat;

    always @(*) begin
        if (sum > 20'sd524287)
            sat = 20'sd524287;        // 正向饱和
        else if (sum < -20'sd524288)
            sat = -20'sd524288;       // 负向饱和
        else
            sat = sum[OUT_BITS-1:0];  // 不越界，直接截取
    end

    // ------------------------------------------------------------------
    // 3. 输出寄存
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mix_out <= {OUT_BITS{1'b0}};
        end
        else if (sample_en) begin
            mix_out <= sat;
        end
    end

endmodule
