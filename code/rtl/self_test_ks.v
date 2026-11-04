// ============================================================================
//  模块名  : self_test_ks.v
//  功能    : 零接线循环播放【Karplus-Strong 拨弦】十二音
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，27 MHz
//
//  ── 说明 ──────────────────────────────────────────────────────────
//  Karplus-Strong（物理建模）的延迟线长度 N = fs / f0 决定音高。
//  C4~B4 对应的 N 在 202~107 之间，所以这里用一张 12 项的小表，
//  而不是从 FCW 反算（避免用除法/倒数）。
//
//  ── 与其它自检固件的关系 ──────────────────────────────────────────
//  结构完全沿用 self_test_12notes（同样的音序、时长、音量、I2S），
//  唯一区别是把 piano_engine 换成 karplus_strong。便于 A/B 对比。
// ============================================================================
`timescale 1ns / 1ps

module self_test_ks #(
    parameter BCK_HALF  = 4,
    parameter HOLD_CLK  = 32'd16_200_000,   // 0.60 s 按住
    parameter GAP_CLK   = 32'd8_100_000,    // 0.30 s 松开
    parameter NOTE_NUM  = 12
)(
    input  wire        clk,
    output wire        i2s_bck,
    output wire        i2s_lrck,
    output wire        i2s_din,
    output wire        pa_en,
    output wire [5:0]  led
);

    // ---- 上电复位 ----
    reg [15:0] por_cnt = 16'd0;
    reg        rst_n   = 1'b0;

    always @(posedge clk) begin
        if (&por_cnt) rst_n <= 1'b1;
        else          por_cnt <= por_cnt + 16'd1;
    end

    // ---- 播放状态机 ----
    localparam S_IDLE = 2'd0;
    localparam S_HOLD = 2'd1;
    localparam S_GAP  = 2'd2;

    reg [1:0]  state;
    reg [3:0]  note_i;
    reg [31:0] cnt;
    reg        note_valid;
    reg        note_on;
    reg        gate;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            note_i     <= 4'd0;
            cnt        <= 32'd0;
            note_valid <= 1'b0;
            note_on    <= 1'b0;
            gate       <= 1'b0;
        end
        else begin
            note_valid <= 1'b0;
            case (state)
                S_IDLE: begin
                    note_valid <= 1'b1;
                    note_on    <= 1'b1;
                    gate       <= 1'b1;
                    cnt        <= 32'd0;
                    state      <= S_HOLD;
                end
                S_HOLD: begin
                    cnt <= cnt + 32'd1;
                    if (cnt >= HOLD_CLK) begin
                        note_valid <= 1'b1;
                        note_on    <= 1'b0;
                        gate       <= 1'b0;
                        cnt        <= 32'd0;
                        state      <= S_GAP;
                    end
                end
                S_GAP: begin
                    cnt <= cnt + 32'd1;
                    if (cnt >= GAP_CLK) begin
                        note_i <= (note_i == (NOTE_NUM - 1)) ? 4'd0 : (note_i + 4'd1);
                        state  <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // ---- 音符 → FCW（保留给接口，KS 实际用下面的长度表）----
    wire [31:0] fcw;
    note_table u_note (
        .note_idx ({1'b0, note_i}),
        .fcw      (fcw)
    );

    // ---- 音符 → 延迟线长度 N = round(52734.375 / f0) ----
    //  C4=261.63 → 202, C#4=277.18 → 190, D4=293.66 → 180, D#4=311.13 → 169
    //  E4=329.63 → 160, F4=349.23 → 151, F#4=369.99 → 143, G4=392.00 → 135
    //  G#4=415.30 → 127, A4=440.00 → 120, A#4=466.16 → 113, B4=493.88 → 107
    function [9:0] ks_length;
        input [3:0] n;
        begin
            case (n)
                4'd0 : ks_length = 10'd202;
                4'd1 : ks_length = 10'd190;
                4'd2 : ks_length = 10'd180;
                4'd3 : ks_length = 10'd169;
                4'd4 : ks_length = 10'd160;
                4'd5 : ks_length = 10'd151;
                4'd6 : ks_length = 10'd143;
                4'd7 : ks_length = 10'd135;
                4'd8 : ks_length = 10'd127;
                4'd9 : ks_length = 10'd120;
                4'd10: ks_length = 10'd113;
                default: ks_length = 10'd107;
            endcase
        end
    endfunction

    wire [9:0] ks_len = ks_length(note_i);

    // ---- Karplus-Strong 引擎 ----
    wire               sample_req;
    wire signed [15:0] raw_audio;
    wire               voice_trig = note_valid & note_on;
    wire               voice_busy = gate;

    karplus_strong #(
        .PHASE_BITS  (32),
        .DEPTH_LOG2  (9)         // 512
    ) u_ks (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_req (sample_req),
        .fcw        (fcw),
        .ks_len     (ks_len),
        .trig       (voice_trig),
        .busy       (voice_busy),
        // 2026-11-04：slow_decay 是新增输入端口。这里原来没接，综合时浮空
        // 会被当成不定值；自检固件固定用钢琴档（1）。
        // 注：DECAY_SHIFT 参数已不再生效（衰减改为慢/快两档硬编码），故删掉。
        .slow_decay (1'b1),
        .audio      (raw_audio)
    );

    // ---- 音量 ×15/16（与其它自检固件一致，便于 A/B 对比）----
    wire signed [16:0] scaled = $signed(raw_audio) - ($signed(raw_audio) >>> 4);
    wire signed [15:0] audio  = scaled[15:0];

    // ---- I2S ----
    i2s_tx #(
        .DATA_BITS (16),
        .BCK_HALF  (BCK_HALF)
    ) u_i2s (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_l   (audio),
        .sample_r   (audio),
        .bck        (i2s_bck),
        .lrck       (i2s_lrck),
        .din        (i2s_din),
        .sample_req (sample_req)
    );

    assign pa_en = 1'b1;

    // ---- LED ----
    reg [23:0] blink;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) blink <= 24'd0;
        else        blink <= blink + 24'd1;
    end

    assign led = ~{ note_i[2:0], gate, blink[23] };

endmodule
