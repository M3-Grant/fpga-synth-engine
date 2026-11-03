// ============================================================================
//  模块名  : self_test_organ.v
//  功能    : 零接线循环播放【管风琴】十二音（验证新音色）
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，27 MHz
//
//  ── 用途 ──────────────────────────────────────────────────────────
//  和 `self_test_12notes` 完全同样的结构，只把 piano_engine 的 TIMBRE
//  参数换成 1（管风琴）。这样"同样的 12 个音"可以在钢琴/管风琴之间直接 A/B 对比。
//
//  ── 管风琴参数（已写进 piano_engine.v 的 TIMBRE==1 分支）────────────
//      谐波：1 : 0.08 : 0.012（基波 + 微量 2/3 次）
//      衰减：s=15 → τ = 32768 采样 ≈ 621 ms（2 秒只衰约 28 dB）
//      听感：圆润、接近纯正弦，和钢琴的"亮→暗"形成强对比
//
//  ── 与钢琴版的可比性 ───────────────────────────────────────────────
//  音序、时长、音量缩放（×15/16）、I2S 配置全部相同 —— 唯一变量是音色。
// ============================================================================
`timescale 1ns / 1ps

module self_test_organ #(
    parameter BCK_HALF  = 4,
    parameter HOLD_CLK  = 32'd16_200_000,   // 0.60 s 按住
    parameter GAP_CLK   = 32'd8_100_000,    // 0.30 s 松开
    parameter NOTE_NUM  = 12,
    parameter TIMBRE    = 2                 // 1 = 管风琴
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

    // ---- 音符 → FCW ----
    wire [31:0] fcw;
    note_table u_note (
        .note_idx ({1'b0, note_i}),
        .fcw      (fcw)
    );

    // ---- 引擎（TIMBRE=1 管风琴）----
    wire               sample_req;
    wire signed [15:0] raw_audio;
    wire [0:0]         voice_trig = note_valid & note_on;
    wire [0:0]         voice_busy = gate;

    piano_engine #(
        .VOICE_NUM  (1),
        .HARM_NUM   (6),
        .PHASE_BITS (32),
        .TIMBRE     (TIMBRE)
    ) u_voice (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_req (sample_req),
        .voice_fcw  (fcw),
        .voice_trig (voice_trig),
        .voice_busy (voice_busy),
        .audio      (raw_audio)
    );

    // ---- 音量 ×15/16（与钢琴版一致，便于 A/B 对比）----
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

    // ---- LED：低 3 位音符序号，[1] 发声，[0] 心跳 ----
    reg [23:0] blink;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) blink <= 24'd0;
        else        blink <= blink + 24'd1;
    end

    assign led = ~{ note_i[2:0], gate, blink[23] };

endmodule
