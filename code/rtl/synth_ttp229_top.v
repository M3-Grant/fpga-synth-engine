// ============================================================================
//  模块名  : synth_ttp229_top.v
//  功能    : 12 键电子琴板级顶层 —— **TTP229 触摸模块版**
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，27 MHz
//
//  ── 与 synth_board12_top 的区别 ────────────────────────────────────
//  synth_board12_top：12 个 TTP223，一个键一根线（12 根并行输入）
//  本模块        ：一块 TTP229 钢琴模块，2 根线串行读出 16 位键状态
//  其余（合成器、红外手势、功放门控、LED）完全一致。
//
//  ── 接线（模块 5P 排针）──────────────────────────────────────────
//      VCC  → 板卡 3V3（**必须 3.3V**，5V 会让 SDO 输出 5V 打坏 IO）
//      GND  → 板卡 GND
//      SCL  → 引脚 75（本模块输出）
//      SDO  → 引脚 76（本模块输入，内部上拉）
//      RGB  → 悬空（模块自带 RGB 灯，本项目不用）
//
//  ── 位映射（重要）─────────────────────────────────────────────────
//  TTP229 扫出 16 位，但"哪一位对应哪个键、是低音在高位还是低位"
//  只能实测。方法：烧 `ttp229_debug` 固件，逐个戳键看 LED 显示的键号，
//  然后把下表里 12 个数字改成实测值即可（TTP_BIT(i) = 第 i 个音
//  对应的 TTP229 位号，0~15）。
//
//  出厂默认假设：低音对应低位、连续 12 位（0~11）。
//  ⚠ 若实测发现方向相反（低音在高位），把表改成 15,14,13...4 即可。
// ============================================================================
module synth_ttp229_top #(
    parameter VOICE_NUM  = 4,
    parameter NOTE_BITS  = 5,
    parameter BCK_HALF   = 4,
    parameter KEY_NUM    = 12,
    parameter KEY_CNT_MAX= 270_000,       // 按键消抖 10 ms
    parameter IR_DEBOUNCE_CNT  = 540_000,   // 红外消抖 20 ms
    parameter IR_MIN_SWIPE_CNT = 2_160_000, // 挥手最短 80 ms
    parameter IR_MAX_SWIPE_CNT = 32_400_000,// 挥手最长 1200 ms
    // TTP229 时序（仿真时可缩短，上板保持默认 200µs/500kHz/20ms）
    parameter TTP_SYNC_CNT = 5_400,
    parameter TTP_SCL_HALF = 27,
    parameter TTP_GAP_CNT  = 540_000,
    parameter TTP_ACTIVE_LOW = 1          // TTP229 输出 0=按下，必须取反
)(
    input  wire        clk,        // 27 MHz，引脚 4
    input  wire        ir_in,      // 红外避障模块（低 = 有手），引脚 74
    output wire        ttp_scl,    // → TTP229 SCL，引脚 75
    input  wire        ttp_sdo,    // ← TTP229 SDO，引脚 76
    input  wire        uart_rx_i, // ← USB-TTL 的 TXD，引脚 70
    output wire        i2s_bck,    // 引脚 56
    output wire        i2s_lrck,   // 引脚 55
    output wire        i2s_din,    // 引脚 54
    output wire        pa_en,      // 引脚 51（新链路可不用）
    output wire [4:0]  uart_tx,    // 串口帧输出（48/69/42/77/79，接一个即可）
    output wire [5:0]  led         // 引脚 15~20（低电平点亮）
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
    // 2. TTP229 串行读出 → 16 位键状态
    // ==================================================================
    wire [15:0] ttp_keys;
    wire        ttp_valid;

    ttp229_scan #(
        .KEY_NUM   (16),
        .SYNC_CNT  (TTP_SYNC_CNT),
        .SCL_HALF  (TTP_SCL_HALF),
        .GAP_CNT   (TTP_GAP_CNT),
        .MSB_FIRST (1)
    ) u_ttp (
        .clk       (clk),
        .rst_n     (rst_n),
        .sdo       (ttp_sdo),
        .scl       (ttp_scl),
        .key_state (ttp_keys),
        .key_valid (ttp_valid)
    );

    // ==================================================================
    // 3. 16 位 → 12 个音（位映射表）
    //    实测后只改这个 function 里的 12 个数字，其它代码不用动
    // ==================================================================
    // ── 实测标定（2026-10-31，Qhebot 12 键钢琴触摸板）──────────────
    //  方法：烧 ttp229_debug，逐个戳键读 LED 位号（LED 1~6 从右往左 = led[0]~led[5]）
    //  实测（C4..B4）：11, 0, 10, 15, 9, 8, 14, 7, 13, 6, 12, 5
    //  注意：只用到了 bit 0 与 5~15，bit 1~4 悬空 —— 这是该模块的走线特点
    function [3:0] TTP_BIT;
        input [3:0] i;            // i = 0..11（C4..B4）
        begin
            case (i)
                4'd0 : TTP_BIT = 4'd11;   // C4
                4'd1 : TTP_BIT = 4'd0;    // C#4
                4'd2 : TTP_BIT = 4'd10;   // D4
                4'd3 : TTP_BIT = 4'd15;   // D#4
                4'd4 : TTP_BIT = 4'd9;    // E4
                4'd5 : TTP_BIT = 4'd8;    // F4
                4'd6 : TTP_BIT = 4'd14;   // F#4
                4'd7 : TTP_BIT = 4'd7;    // G4
                4'd8 : TTP_BIT = 4'd13;   // G#4
                4'd9 : TTP_BIT = 4'd6;    // A4
                4'd10: TTP_BIT = 4'd12;   // A#4
                default: TTP_BIT = 4'd5;  // B4
            endcase
        end
    endfunction

    wire [KEY_NUM-1:0] key;

    genvar gi;
    generate
        for (gi = 0; gi < KEY_NUM; gi = gi + 1) begin : gen_keymap
            // TTP229 是低有效（0 = 按下），这里按参数取反
            assign key[gi] = TTP_ACTIVE_LOW ? ~ttp_keys[TTP_BIT(gi)]
                                            :  ttp_keys[TTP_BIT(gi)];
        end
    endgenerate

    // ==================================================================
    // 4. 12 路按键扫描（复用原模块，ACTIVE_LOW=0 与 TTP229 的高有效一致）
    // ==================================================================
    wire [KEY_NUM-1:0] key_state;
    wire               note_valid;
    wire               note_on;
    wire [NOTE_BITS-1:0] note_idx;

    key_scan #(
        .KEY_NUM    (KEY_NUM),
        .CNT_MAX    (KEY_CNT_MAX),
        .ACTIVE_LOW (0),
        .NOTE_BITS  (NOTE_BITS)
    ) u_keys (
        .clk       (clk),
        .rst_n     (rst_n),
        .key_in    (key),
        .key_state (key_state),
        .note_valid(note_valid),
        .note_on   (note_on),
        .note_idx  (note_idx)
    );

    // ==================================================================
    // 5. 红外手势 → 音色切换（第二演奏维度）
    // ==================================================================
    wire [2:0] ir_wave;              // 红外维护的音色
    wire [2:0] ui_wave;              // 上位机指定的音色
    wire       ui_active;            // 1 = UI 在控，0 = 红外在控
    wire [2:0] wave_sel = ui_active ? ui_wave : ir_wave;   // 最终音色（硬件优先）
    wire       ir_gesture_valid;
    wire       ir_hand;
    wire       swipe_tooshort;
    wire       swipe_toolong;

    ir_gesture #(
        .DEBOUNCE_CNT  (IR_DEBOUNCE_CNT),
        .MIN_SWIPE_CNT (IR_MIN_SWIPE_CNT),
        .MAX_SWIPE_CNT (IR_MAX_SWIPE_CNT),
        .INIT_SEL      (3'b100),         // 复位默认：钢琴
        .N_COLORS      (5)
    ) u_ir (
        .clk           (clk),
        .rst_n         (rst_n),
        .ir_in         (ir_in),
        .wave_sel      (ir_wave),        // 红外维护的音色（最终音色在外部选择）
        .gesture_valid (ir_gesture_valid),
        .hand_level    (ir_hand),
        .swipe_tooshort(swipe_tooshort),
        .swipe_toolong (swipe_toolong)
    );

    // ==================================================================
    // 5b. 上位机下行命令（UI 实时切音色）
    //     硬件优先：挥手时 ui_cmd 的 clr_i 拉高，立刻交回红外控制
    // ==================================================================
    wire [7:0] ui_rx_data;
    wire       ui_rx_valid;

    uart_rx #(
        .CLK_HZ (27_000_000),
        .BAUD   (115200)
    ) u_ui_rx (
        .clk   (clk),
        .rst_n (rst_n),
        .rx    (uart_rx_i),
        .data  (ui_rx_data),
        .valid (ui_rx_valid)
    );

    ui_cmd u_ui_cmd (
        .clk      (clk),
        .rst_n    (rst_n),
        .rx_data  (ui_rx_data),
        .rx_valid (ui_rx_valid),
        .clr_i    (ir_gesture_valid),     // 挥手 → 交回红外
        .ui_wave  (ui_wave),
        .ui_active(ui_active)
    );

    // ==================================================================
    // 6. 复音合成器
    // ==================================================================
    wire [VOICE_NUM-1:0] dbg_voice_busy;
    wire signed [15:0]   dbg_mix;

    synth_top #(
        .VOICE_NUM  (VOICE_NUM),
        .PHASE_BITS (32),
        .BCK_HALF   (BCK_HALF),
        .AMP        (16'sh3000),
        .NOTE_BITS  (NOTE_BITS)
    ) u_synth (
        .clk            (clk),
        .rst_n          (rst_n),
        .note_valid     (note_valid),
        .note_on        (note_on),
        .note_idx       (note_idx),
        .wave_sel       (wave_sel),
        .i2s_bck        (i2s_bck),
        .i2s_lrck       (i2s_lrck),
        .i2s_din        (i2s_din),
        .dbg_voice_busy (dbg_voice_busy),
        .dbg_mix        (dbg_mix),
        .dbg_sample_req (i2s_sample_req),
        .dbg_audio_out  (i2s_audio_out)
    );

    // ==================================================================
    // 6b. 串口帧输出（给上位机 synth_viz.py）
    // ==================================================================
    wire        i2s_sample_req;
    wire signed [15:0] i2s_audio_out;

    uart_stream #(
        .CLK_HZ (27_000_000),
        .BAUD   (115200),
        .DECIM  (7)
    ) u_uart (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_en  (i2s_sample_req),
        .audio      (i2s_audio_out),
        .keys       (key_state),
        .timbre     (wave_sel),
        .voices     ({2'b00, (|dbg_voice_busy)}),
        .uart_tx    (uart_tx_line),
        .frame_busy (frame_busy)
    );

    wire uart_tx_line;
    wire frame_busy;
    assign uart_tx = {5{uart_tx_line}};

    // ==================================================================
    // 7. 功放使能
    //    新链路（PCM5102A + PAM8403）不认这个信号，可悬空；
    //    若仍用板载 MAX98357A，这里保留门控降温逻辑。
    // ==================================================================
    wire any_busy = |dbg_voice_busy;
    reg [21:0] pa_hold;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                pa_hold <= 22'd0;
        else if (any_busy)         pa_hold <= 22'h3F_FFFF;
        else if (pa_hold != 22'd0) pa_hold <= pa_hold - 22'd1;
    end

    assign pa_en = (pa_hold != 22'd0);

    // ==================================================================
    // 8. LED 指示（低电平点亮）
    //    led[0] 心跳 / led[1] 发声 / led[2] 按键事件 / led[3] 红外有手
    // ==================================================================
    reg [23:0] blink;
    reg        evt_stretch;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blink       <= 24'd0;
            evt_stretch <= 1'b0;
        end
        else begin
            blink <= blink + 24'd1;
            if (note_valid)                  evt_stretch <= 1'b1;
            else if (blink[22:0] == 23'd0)   evt_stretch <= 1'b0;
        end
    end

    wire [5:0] led_on = {
        2'b00,           // [5:4] 预留
        ir_hand,         // [3]   红外检测到手
        evt_stretch,     // [2]   按键事件
        any_busy,        // [1]   正在发声
        blink[23]        // [0]   心跳
    };

    assign led = ~led_on;

endmodule
