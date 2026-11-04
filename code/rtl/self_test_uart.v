// ============================================================================
//  模块名  : self_test_uart.v
//  功能    : self_test_12notes + 串口帧输出（给上位机 synth_viz.py）
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，27 MHz
//
//  ── 用途 ──────────────────────────────────────────────────────────
//  零接线就能让上位机看到真实数据：钢琴十二音自动循环，同时每 ~68 ms
//  通过 UART 发一帧 576 字节（音色/按键/声部/512 采样）给 PC。
//
//  ── 接线 ──────────────────────────────────────────────────────────
//      FPGA 引脚 48（本工程选择）→ USB-TTL 的 RXD
//      GND                        → USB-TTL 的 GND
//      （USB-TTL 电平跳线拨 3V3，TXD 不用接）
//
//  ── 与 self_test_12notes 的差别 ───────────────────────────────────
//  只多了一个 uart_stream 实例；音频通路完全一致（同样的 12 音循环、
//  同样的钢琴引擎、同样的 ×15/16 音量）。
// ============================================================================
`timescale 1ns / 1ps

module self_test_uart #(
    parameter BCK_HALF  = 4,
    parameter HOLD_CLK  = 32'd16_200_000,
    parameter GAP_CLK   = 32'd8_100_000,
    parameter NOTE_NUM  = 12
)(
    input  wire        clk,
    output wire        i2s_bck,
    output wire        i2s_lrck,
    output wire        i2s_din,
    output wire        pa_en,
    output wire [4:0]  uart_tx,       // → 5 个引脚同时输出（48/69/42/77/79，接哪个都行）
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

    // ---- 钢琴引擎（单声部）----
    wire               sample_req;
    wire signed [15:0] raw_audio;
    wire [0:0]         voice_trig = note_valid & note_on;
    wire [0:0]         voice_busy = gate;

    piano_engine #(
        .VOICE_NUM  (1),
        .HARM_NUM   (6),
        .PHASE_BITS (32)
    ) u_piano (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_req (sample_req),
        .voice_fcw  (fcw),
        .voice_trig (voice_trig),
        .voice_busy (voice_busy),
        .audio      (raw_audio)
    );

    // ---- 音量 ×15/16 ----
    wire signed [16:0] scaled   = $signed(raw_audio) - ($signed(raw_audio) >>> 4);
    wire signed [15:0] audio    = scaled[15:0];

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

    // ---- 功放常开 ----
    assign pa_en = 1'b1;

    // ==================================================================
    // 串口帧输出
    //   按键：把当前音符做成 one-hot 的 12 位（上位机用来点亮琴键）
    //   音色：本固件固定钢琴（3'b100）
    //   声部：发声中为 1，否则 0
    // ==================================================================
    reg [11:0] key_onehot;
    always @(*) begin
        key_onehot = 12'd0;
        if (gate) key_onehot[note_i] = 1'b1;
    end

    wire frame_busy;
    wire tx_line;

    uart_stream #(
        .CLK_HZ   (27_000_000),
        .BAUD     (115200),
        .DECIM    (7)
    ) u_uart (
        .clk       (clk),
        .rst_n     (rst_n),
        .sample_en (sample_req),
        .audio     (audio),
        .keys      (key_onehot),
        .timbre    (3'b100),          // 钢琴
        .voices    ({2'b00, gate}),
        .uart_tx   (tx_line),
        .frame_busy(frame_busy),
        // 本自检固件没有延迟测量与红外，全部接空
        .lat_last  (32'd0), .lat_min (32'hFFFF_FFFF), .lat_max (32'd0),
        .lat_sum   (32'd0), .lat_cnt (16'd0), .lat_valid (1'b0),
        .hist0 (16'd0), .hist1 (16'd0), .hist2 (16'd0), .hist3 (16'd0),
        .hist4 (16'd0), .hist5 (16'd0), .hist6 (16'd0), .hist7 (16'd0),
        .hist8 (16'd0), .hist9 (16'd0), .hist10(16'd0), .hist11(16'd0),
        .hist12(16'd0), .hist13(16'd0), .hist14(16'd0), .hist15(16'd0),
        .ir_hand (2'b00), .ir_gesture_cnt (8'd0), .ir_short_cnt (8'd0), .ir_long_cnt (8'd0)
    );

    // ---- LED：低 3 位显示音符序号；[2] 发声中；[1] 正在发串口帧；[0] 心跳 ----
    reg [23:0] blink;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) blink <= 24'd0;
        else        blink <= blink + 24'd1;
    end

    assign uart_tx = {5{tx_line}};   // 5 个脚同时发，接哪个都能收到

    assign led = ~{ note_i[2:0], gate, frame_busy, blink[23] };

endmodule
