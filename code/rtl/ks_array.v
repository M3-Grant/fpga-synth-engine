// ============================================================================
//  模块名  : ks_array.v
//  功能    : N 路 Karplus-Strong 拨弦引擎 + 混音（参数已冻结）
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，27 MHz
//
//  ── 冻结参数（2026-10-31 实测定稿）────────────────────────────────
//      反馈低通   (a+3b)/4        —— 比 (a+b)/2 暗、比 (a+7b)/8 亮
//      激励噪声   三级低通 + 幅度 1/4
//      衰减       y - (y>>6)      —— 约 0.984/次
//      延迟线     512 深 × 16bit（每声部一块 BRAM）
// ============================================================================
`timescale 1ns / 1ps

module ks_array #(
    parameter VOICE_NUM   = 4,
    parameter PHASE_BITS  = 32,
    parameter DEPTH_LOG2  = 9,          // 512
    parameter DECAY_SHIFT = 6
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       sample_req,
    input  wire [VOICE_NUM*5-1:0]     voice_note,    // 每声部音名（0..11）
    input  wire [VOICE_NUM-1:0]       voice_trig,    // 起音脉冲
    input  wire [VOICE_NUM-1:0]       voice_busy,    // 1=发声中
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

            karplus_strong #(
                .PHASE_BITS  (PHASE_BITS),
                .DEPTH_LOG2  (DEPTH_LOG2),
                .DECAY_SHIFT (DECAY_SHIFT)
            ) u_ks (
                .clk        (clk),
                .rst_n      (rst_n),
                .sample_req (sample_req),
                .fcw        ({PHASE_BITS{1'b0}}),
                .ks_len     (len_v),
                .trig       (voice_trig[gv]),
                .busy       (voice_busy[gv]),
                .audio      (aud[gv])
            );
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
