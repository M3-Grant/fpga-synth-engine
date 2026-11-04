// ============================================================================
//  模块名  : ks_array.v
//  功能    : N 路 Karplus-Strong 拨弦引擎 + 混音（钢琴/拨弦共用）
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，27 MHz
//
//  ── 2026-11-04 钢琴化改造 ──────────────────────────────────────────
//  真实钢琴一个音通常有 2~3 根弦，长度有极小差异，振动叠加后产生缓慢
//  拍频（beating），这是钢琴听起来"厚"和"活"的原因。
//
//  本版：前 DUAL_VOICES 个声部放 2 根弦（长度 N 与 N+1），
//        其余声部单弦。双弦两路等权平均，幅度与单弦一致。
//
//  为什么不是全部双弦：8 个 KS 实例综合后逻辑 28648 > 器件上限 20736。
//  前 3 个声部双弦（7 个实例）既能弹三和弦，又落在资源预算内。
//
//  ── 延迟线深度 ────────────────────────────────────────────────────
//  512 深足够覆盖本琴 12 键（C4 需要 202）。深度减半并不能省多少 LUT，
//  因为开销主要在控制逻辑而不是地址位宽。
// ============================================================================
`timescale 1ns / 1ps

module ks_array #(
    parameter VOICE_NUM   = 4,
    parameter DUAL_VOICES = 3,          // 前几个声部使用双弦
    parameter PHASE_BITS  = 32,
    parameter DEPTH_LOG2  = 9,          // 512
    parameter DECAY_SHIFT = 8           // 钢琴档 8（约 1 s），吉他档可调小
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       sample_req,
    input  wire [VOICE_NUM*5-1:0]     voice_note,    // 每声部音名（0..11）
    input  wire [VOICE_NUM-1:0]       voice_trig,    // 起音脉冲
    input  wire [VOICE_NUM-1:0]       voice_busy,    // 1=发声中
    input  wire                       piano_mode,    // 1=钢琴(慢衰减) 0=拨弦(快衰减)
    output wire signed [15:0]         audio
);

    // 音名 → 延迟线长度 N = round(52734.375 / f0)
    function [9:0] ks_len_of;
        input [4:0] n;
        begin
            case (n[3:0])
                4'd0 : ks_len_of = 10'd202;   // C4
                4'd1 : ks_len_of = 10'd190;
                4'd2 : ks_len_of = 10'd180;
                4'd3 : ks_len_of = 10'd169;
                4'd4 : ks_len_of = 10'd160;
                4'd5 : ks_len_of = 10'd151;
                4'd6 : ks_len_of = 10'd143;
                4'd7 : ks_len_of = 10'd135;
                4'd8 : ks_len_of = 10'd127;
                4'd9 : ks_len_of = 10'd120;
                4'd10: ks_len_of = 10'd113;
                default: ks_len_of = 10'd107; // B4
            endcase
        end
    endfunction

    wire signed [15:0] aud [0:VOICE_NUM-1];

    genvar gv;
    generate
        for (gv = 0; gv < VOICE_NUM; gv = gv + 1) begin : gen_ks
            wire [4:0] note_v = voice_note[gv*5 +: 5];
            wire [9:0] len_v  = ks_len_of(note_v);

            // ---- 弦 A：所有声部都有 ----
            wire signed [15:0] aud_a;
            karplus_strong #(
                .PHASE_BITS  (PHASE_BITS),
                .DEPTH_LOG2  (DEPTH_LOG2),
                .DECAY_SHIFT (DECAY_SHIFT)
            ) u_ks_a (
                .clk        (clk),
                .rst_n      (rst_n),
                .sample_req (sample_req),
                .fcw        ({PHASE_BITS{1'b0}}),
                .ks_len     (len_v),
                .trig       (voice_trig[gv]),
                .busy       (voice_busy[gv]),
                .slow_decay (piano_mode),
                .audio      (aud_a)
            );

            if (gv < DUAL_VOICES) begin : g_dual
                // ---- 弦 B：长 1 个采样，形成缓慢拍频 ----
                wire signed [15:0] aud_b;
                karplus_strong #(
                    .PHASE_BITS  (PHASE_BITS),
                    .DEPTH_LOG2  (DEPTH_LOG2),
                    .DECAY_SHIFT (DECAY_SHIFT)
                ) u_ks_b (
                    .clk        (clk),
                    .rst_n      (rst_n),
                    .sample_req (sample_req),
                    .fcw        ({PHASE_BITS{1'b0}}),
                    .ks_len     (len_v + 10'd1),
                    .trig       (voice_trig[gv]),
                    .busy       (voice_busy[gv]),
                    .slow_decay (piano_mode),
                    .audio      (aud_b)
                );
                // 双弦平均：17 位中间量防溢出
                wire signed [16:0] mix2 = aud_a + aud_b;
                assign aud[gv] = mix2[16:1];
            end
            else begin : g_single
                assign aud[gv] = aud_a;
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // 混音 + 饱和
    // ------------------------------------------------------------------
    integer i;
    reg signed [19:0] sum;
    always @(*) begin
        sum = 20'sd0;
        for (i = 0; i < VOICE_NUM; i = i + 1)
            sum = sum + $signed(aud[i]);
    end

    wire signed [19:0] sat = (sum > 20'sd32767)  ? 20'sd32767 :
                             (sum < -20'sd32768) ? -20'sd32768 : sum;

    assign audio = sat[15:0];

endmodule
