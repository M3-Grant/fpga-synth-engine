// ============================================================================
//  模块名  : self_test_square.v
//  功能    : 最小实现对照测试 —— 零接线循环播放**方波**十二音（C4~B4）
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，27 MHz
//
//  ── 为什么需要它 ──────────────────────────────────────────────────
//  self_test_12notes 用的是钢琴引擎（6 次谐波加法合成）。若上板听感
//  "发干、发硬、像电子琴"，有两种可能：
//      ① 钢琴引擎的谐波计算有精度损失（数字侧）
//      ② 功放/喇叭的频响与失真（硬件侧）
//  本固件把音频源换成**最原始的方波**（一个相位累加器 + 取最高位，
//  没有任何乘法、没有任何混音、没有包络），其余条件（12 音序列、
//  0.6s/0.3s 节奏、50% 幅度、pa_en 常开、i2s_tx）全部保持一致。
//  → 方波干净而钢琴发怪 = 钢琴引擎的问题
//  → 方波也发怪       = 硬件的问题
//
//  ── 与 tone_test 的区别 ──────────────────────────────────────────
//  tone_test 固定播 A4 一个音；本固件跑完整十二音循环，便于逐个听音高。
//
//  ── 音量 ──────────────────────────────────────────────────────────
//  AMP = 16'sh4000 = 16384 ≈ 50% 满量程，与钢琴版（51.5%）基本一致，
//  这样两者的响度可以直接对比。
// ============================================================================
`timescale 1ns / 1ps

module self_test_square #(
    parameter BCK_HALF  = 4,
    parameter HOLD_CLK  = 32'd16_200_000,  // 0.60 s @27MHz
    parameter GAP_CLK   = 32'd8_100_000,   // 0.30 s @27MHz
    parameter NOTE_NUM  = 12,
    parameter AMP       = 16'sh7FFF        // 满幅（最大音量测试）
)(
    input  wire        clk,
    output wire        i2s_bck,
    output wire        i2s_lrck,
    output wire        i2s_din,
    output wire        pa_en,
    output wire [5:0]  led
);

    // ==================================================================
    // 1. 上电复位
    // ==================================================================
    reg [15:0] por_cnt = 16'd0;
    reg        rst_n   = 1'b0;

    always @(posedge clk) begin
        if (&por_cnt) rst_n <= 1'b1;
        else          por_cnt <= por_cnt + 16'd1;
    end

    // ==================================================================
    // 2. 播放状态机：IDLE → HOLD → GAP → 下一个音
    // ==================================================================
    localparam S_IDLE = 2'd0;
    localparam S_HOLD = 2'd1;
    localparam S_GAP  = 2'd2;

    reg [1:0]  state;
    reg [3:0]  note_i;
    reg [31:0] cnt;
    reg        gate;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            note_i <= 4'd0;
            cnt    <= 32'd0;
            gate   <= 1'b0;
        end
        else begin
            case (state)
                S_IDLE: begin
                    gate  <= 1'b1;
                    cnt   <= 32'd0;
                    state <= S_HOLD;
                end
                S_HOLD: begin
                    cnt <= cnt + 32'd1;
                    if (cnt >= HOLD_CLK) begin
                        gate  <= 1'b0;
                        cnt   <= 32'd0;
                        state <= S_GAP;
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

    // ==================================================================
    // 3. 音符 → 频率控制字
    // ==================================================================
    wire [31:0] fcw;

    note_table u_note (
        .note_idx ({1'b0, note_i}),
        .fcw      (fcw)
    );

    // ==================================================================
    // 4. 方波：相位累加器取最高位（与 tone_test_top 完全相同的做法）
    //    没有任何乘法、混音、包络 —— 用来把"数字侧复杂度"压到最低
    // ==================================================================
    wire        sample_req;
    reg  [31:0] phase;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)           phase <= 32'd0;
        else if (sample_req)  phase <= phase + fcw;
    end

    wire signed [15:0] audio = phase[31] ? AMP : -AMP;

    // ==================================================================
    // 5. I2S 发送
    // ==================================================================
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

    // ==================================================================
    // 6. 功放常开（自检不需要省电；门控会在每音之间造成 POP）
    // ==================================================================
    assign pa_en = 1'b1;

    // ==================================================================
    // 7. LED：led[0] 心跳、led[1] 发声、led[5:2] 当前音符序号
    // ==================================================================
    reg [23:0] blink;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) blink <= 24'd0;
        else        blink <= blink + 24'd1;
    end

    assign led = ~{ note_i, gate, blink[23] };

endmodule
