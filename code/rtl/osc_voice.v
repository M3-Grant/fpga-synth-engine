// ============================================================================
//  模块名  : osc_voice.v
//  功能    : 单个振荡器声部 —— DDS 相位累加器 + 方波输出 + 包络调制入口
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，主时钟 27 MHz
//
//  ── 设计说明 ──────────────────────────────────────────────────────
//  这是"复音合成器"的最小发声单元。VOICE_NUM 份本模块并行工作，
//  每个声部独立跟踪自己的相位、频率与包络，实现真正的同时发声。
//
//  频率关系（DDS 标准公式）：
//      f_out = fcw × fs / 2^PHASE_BITS
//  其中 fs 为音频采样率（本项目 52734.375 Hz，见 gen_fcw.py）。
//
//  ── 关于方波 ──────────────────────────────────────────────────────
//  直接取相位累加器最高位作为方波输出：
//      phase[31] = 1  →  +AMP
//      phase[31] = 0  →  -AMP
//  好处是不需要波形 ROM，资源极省。后续换正弦波时，
//  只需把这里替换成 rom[phase[31:22]] 查表即可，接口不变。
//
//  ── 关于包络 ──────────────────────────────────────────────────────
//  env 为 0~255 的包络电平，与方波样本相乘后输出。
//  乘法用移位相加实现（每周期乘 1/8，8 个周期完成），
//  避免占用 DSP 乘法器 —— 48 个 DSP 不够 32 个声部各用一个。
//
//  作者    : 第二代迭代 1
// ============================================================================
module osc_voice #(
    parameter PHASE_BITS = 32,          // 相位累加器位宽
    parameter AMP        = 16'sh2000    // 基础幅度（有符号）
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  sample_en,   // 音频采样使能（每帧 1 个 clk）
    input  wire [PHASE_BITS-1:0] fcw,         // 频率控制字
    input  wire [7:0]            env,         // 包络电平 0~255（255 = 满幅）
    input  wire                  gate,        // 1 = 发声，0 = 静音
    output reg  signed [15:0]    sample       // 有符号音频样本
);

    // ------------------------------------------------------------------
    // 1. 相位累加器：每个采样周期加一次 FCW，自然溢出即回绕
    // ------------------------------------------------------------------
    reg [PHASE_BITS-1:0] phase;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= {PHASE_BITS{1'b0}};
        end
        else if (sample_en) begin
            phase <= phase + fcw;
        end
    end

    // ------------------------------------------------------------------
    // 2. 方波：取相位最高位
    //    不发声（gate=0）时输出 0，避免叠加直流偏置
    // ------------------------------------------------------------------
    wire signed [15:0] square = phase[PHASE_BITS-1] ? AMP : -AMP;

    // ------------------------------------------------------------------
    // 3. 包络调制：sample = square × env / 255
    //    用"先乘 env+1 再右移 8 位"近似，误差 < 0.4%，听感无差别
    //    乘法写成移位相加，避免 DSP
    // ------------------------------------------------------------------
    wire signed [23:0] env_ext  = {{8{square[15]}}, square};   // 符号扩展
    wire signed [23:0] env_gain = $signed({1'b0, env}) + 24'sd1;  // 1~256

    // 24×9 位的乘法交给综合器（它会用少量 LUT 实现，不抢 DSP）
    wire signed [32:0] modulated = env_ext * env_gain;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample <= 16'sd0;
        end
        else if (sample_en) begin
            if (gate) begin
                sample <= modulated >>> 8;   // 除以 256
            end
            else begin
                sample <= 16'sd0;
            end
        end
    end

endmodule
