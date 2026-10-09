// ============================================================================
//  模块名  : synth_top.v
//  功能    : 复音合成器顶层 —— 把分配器/振荡器阵列/混音器/I2S 串成完整链路
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，主时钟 27 MHz
//
//  ── 数据流 ────────────────────────────────────────────────────────
//    音符事件 → note_alloc → 声部音符索引
//                  ↓
//              note_table（音符→FCW）
//                  ↓
//          oscillator_array（N 个并行振荡器）
//                  ↓
//              mix_tree（求和 + 饱和）
//                  ↓
//               i2s_tx → DAC
//
//  ── 迭代状态 ──────────────────────────────────────────────────────
//  迭代 1（本次）：复音 4、方波、固定包络、可验证的分配逻辑
//  迭代 2（下一步）：加 ADSR 包络，让声音有起落
//  迭代 3：换正弦波表、加音色切换
//
//  ── 关于包络 ──────────────────────────────────────────────────────
//  本版用固定满幅（env = 255），因为 GS 的包络模块还没做。
//  这样做能先验证"复音架构"是否正确 —— 任务拆分，一次只引入一个新变量。
//
//  作者    : 第二代迭代 1
// ============================================================================
module synth_top #(
    parameter VOICE_NUM  = 4,          // 复音数（改这里即可扩复音）
    parameter PHASE_BITS = 32,
    parameter BCK_HALF   = 4,          // I2S BCK 半周期，决定 fs = 52734.375 Hz
    parameter AMP        = 16'sh2000,  // 单声部幅度
    parameter NOTE_BITS  = 5           // 音符索引位宽（0~24）
)(
    input  wire                    clk,       // 27 MHz
    input  wire                    rst_n,
    // ---- 音符事件输入 ----
    input  wire                    note_valid,
    input  wire                    note_on,
    input  wire [NOTE_BITS-1:0]    note_idx,
    // ---- I2S 输出 ----
    output wire                    i2s_bck,
    output wire                    i2s_lrck,
    output wire                    i2s_din,
    // ---- 调试观测口（综合时可忽略）----
    output wire [VOICE_NUM-1:0]    dbg_voice_busy,
    output wire signed [15:0]      dbg_mix
);

    // ==================================================================
    // 1. 样本请求信号（由 i2s_tx 产生）
    // ==================================================================
    wire sample_req;

    // ==================================================================
    // 2. 音符分配器
    // ==================================================================
    wire [VOICE_NUM-1:0]              voice_busy;
    wire [VOICE_NUM*NOTE_BITS-1:0]    voice_note;
    wire [VOICE_NUM-1:0]              voice_trig;

    note_alloc #(
        .VOICE_NUM (VOICE_NUM),
        .NOTE_BITS (NOTE_BITS)
    ) u_alloc (
        .clk        (clk),
        .rst_n      (rst_n),
        .note_valid (note_valid),
        .note_on    (note_on),
        .note_idx   (note_idx),
        .voice_busy (voice_busy),
        .voice_note (voice_note),
        .voice_trig (voice_trig)
    );

    // ==================================================================
    // 3. 音符 → 频率控制字（每个声部一个查表）
    //    注意：note_table 是组合逻辑查表，VOICE_NUM 份并行例化
    // ==================================================================
    wire [VOICE_NUM*PHASE_BITS-1:0] voice_fcw;

    genvar g;
    generate
        for (g = 0; g < VOICE_NUM; g = g + 1) begin : gen_fcw
            note_table u_note (
                .note_idx (voice_note[g*NOTE_BITS +: NOTE_BITS]),
                .fcw      (voice_fcw[g*PHASE_BITS +: PHASE_BITS])
            );
        end
    endgenerate

    // ==================================================================
    // 4. ADSR 包络（每声部一份，独立控制）
    //    触发：voice_trig 是 note-on 瞬间的单周期脉冲
    //    门控：gate = 1 表示该声部应持续发声
    //         · 分配瞬间（trig）→ gate 置 1，触发 ATTACK
    //         · 声部释放（busy 落）→ gate 置 0，进入 RELEASE
    // ==================================================================
    wire [VOICE_NUM*8-1:0] voice_env;

    generate
        for (g = 0; g < VOICE_NUM; g = g + 1) begin : gen_adsr
            adsr #(
                .ENV_BITS  (8),
                .SUS_LEVEL (8'd160),      // 持续电平（0.63 满幅，留混音余量）
                .ATK_STEP  (8'd8),        // 起音较快
                .DEC_STEP  (8'd2),
                .REL_STEP  (8'd3)         // 余韵约 50 个采样周期
            ) u_adsr (
                .clk       (clk),
                .rst_n     (rst_n),
                .sample_en (sample_req),
                .note_on   (voice_trig[g] | voice_busy[g]),
                .gate      (voice_busy[g]),
                .env       (voice_env[g*8 +: 8])
            );
        end
    endgenerate

    // ==================================================================
    // 5. 振荡器阵列
    // ==================================================================
    wire [VOICE_NUM*16-1:0] voice_sample;

    oscillator_array #(
        .VOICE_NUM  (VOICE_NUM),
        .PHASE_BITS (PHASE_BITS),
        .AMP        (AMP)
    ) u_osc_array (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_en    (sample_req),
        .voice_fcw    (voice_fcw),
        .voice_env    (voice_env),
        .voice_gate   (voice_busy),
        .voice_sample (voice_sample)
    );

    // ==================================================================
    // 6. 混音（输出 20 位有符号）
    // ==================================================================
    wire signed [19:0] mix_out;

    mix_tree #(
        .VOICE_NUM (VOICE_NUM),
        .IN_BITS   (16),
        .OUT_BITS  (20)
    ) u_mix (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_en  (sample_req),
        .samples_in (voice_sample),
        .mix_out    (mix_out)
    );

    // ==================================================================
    // 7. 输出缩放：20 位混音 → 16 位 I2S 样本
    //    右移 2 位（除以 4）留出余量，避免满量程削波
    // ==================================================================
    wire signed [15:0] audio_out = mix_out[17:2];

    // ==================================================================
    // 8. I2S 发送
    // ==================================================================
    i2s_tx #(
        .DATA_BITS (16),
        .BCK_HALF  (BCK_HALF)
    ) u_i2s (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_l   (audio_out),
        .sample_r   (audio_out),
        .bck        (i2s_bck),
        .lrck       (i2s_lrck),
        .din        (i2s_din),
        .sample_req (sample_req)
    );

    // ==================================================================
    // 9. 调试观测口
    // ==================================================================
    assign dbg_voice_busy = voice_busy;
    assign dbg_mix        = audio_out;

endmodule
