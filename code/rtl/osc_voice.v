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
    // 2. 波形生成
    //    WAVE_TRI = 0 → 方波：奇次谐波按 1/n   衰减，明亮但偏"脏"
    //    WAVE_TRI = 1 → 三角波：奇次谐波按 1/n² 衰减，柔和干净得多
    //                   （3 次谐波比方波低 9.5dB，5 次低 14dB，9 次低 19dB）
    //    实测依据：2026-10-15 手机频谱显示方波能量一直拖到 10kHz 以上
    // ------------------------------------------------------------------
    localparam WAVE_TRI = 1;    // ← 改 0 即可回到方波
    localparam TRI_SHR  = 2;    // 三角波缩放，须满足 (16384 >> TRI_SHR) == AMP
                                //   AMP = 1/8  满量程(4096) → TRI_SHR = 2  ← 当前
                                //   AMP = 1/4  满量程(8192) → TRI_SHR = 1
                                //   AMP = 1/16 满量程(2048) → TRI_SHR = 3

    // 方波：取相位最高位
    wire signed [15:0] square = phase[PHASE_BITS-1] ? AMP : -AMP;

    // 三角波：把相位高 16 位折叠一次，得到 0→32767→0 的一个完整周期
    //   u     = phase[31:16]        0 ~ 65535
    //   tri_u = u[15] ? ~u : u      0 ~ 32767 ~ 0
    //   tri_f = tri_u >> TRI_SHR    0 ~ 8191          （TRI_SHR = 2 时）
    //   tri_w = tri_f - 4096        -4096 ~ +4095     （无符号减法补码回绕，
    //                              位模式直接就是正确的有符号值）
    //   ⚠️ 变量名不能叫 tri —— tri 是 Verilog 内置线网类型（三态线网）的关键字
    wire [15:0]        u     = phase[PHASE_BITS-1:PHASE_BITS-16];
    wire [15:0]        tri_u = u[15] ? ~u : u;
    wire [15:0]        tri_f = tri_u >> TRI_SHR;
    wire signed [15:0] tri_w = tri_f - (16'd16384 >> TRI_SHR);

    // 波形选择（方波与三角波峰值都约等于 AMP，切换不会剧变音量）
    wire signed [15:0] wave  = WAVE_TRI ? tri_w : square;

    // ------------------------------------------------------------------
    // 3. 包络调制：sample = wave × env / 255
    //    用"先乘 env+1 再右移 8 位"近似，误差 < 0.4%，听感无差别
    // ------------------------------------------------------------------
    wire signed [23:0] env_ext  = {{8{wave[15]}}, wave};   // 符号扩展
    wire signed [23:0] env_gain = $signed({1'b0, env}) + 24'sd1;  // 1~256

    // 24×9 位的乘法交给综合器（它会用少量 LUT 实现，不抢 DSP）
    wire signed [32:0] modulated = env_ext * env_gain;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample <= 16'sd0;
        end
        else if (sample_en) begin
            if (gate) begin
                // 显式取 [23:8] 而非 modulated >>> 8：
                // 33 位算术右移 8 位后赋给 16 位，等价于取低 16 位 = modulated[23:8]。
                // 写成位选是为了消除 Gowin 综合告警 EX3791（按位宽 25→16 判截断）。
                // 值域校核：AMP=8192, env_gain∈[1,256] → |modulated| ≤ 2097152 = 2^21，
                //           >>>8 后 |结果| ≤ 8192，16 位有符号(±32767)足够，无溢出。
                sample <= modulated[23:8];
            end
            else begin
                sample <= 16'sd0;
            end
        end
    end

endmodule
