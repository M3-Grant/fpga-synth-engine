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
    parameter VOICE_NUM  = 4,   // 4 声部（6 声部会超出 GW2AR-18 的寄存器资源）
    parameter NOTE_BITS  = 5,
    parameter BCK_HALF   = 4,
    parameter KEY_NUM    = 12,
    parameter KEY_CNT_MAX= 135_000,       // 按键消抖 5 ms（只改消抖，扫描保持 20ms）
    parameter IR_DEBOUNCE_CNT  = 540_000,   // 红外消抖 20 ms
    parameter IR_MIN_SWIPE_CNT = 2_160_000, // 挥手最短 80 ms
    parameter IR_MAX_SWIPE_CNT = 32_400_000,// 挥手最长 1200 ms
    // TTP229 时序（仿真时可缩短，上板保持默认 200µs/500kHz/20ms）
    parameter TTP_SYNC_CNT = 5_400,
    parameter TTP_SCL_HALF = 27,
    parameter TTP_GAP_CNT  = 540_000,      // 20 ms
    parameter TTP_ACTIVE_LOW = 1           // TTP229 输出 0=按下，必须取反
)(
    input  wire        clk,        // 27 MHz，引脚 4
    input  wire        ir_in,      // 红外 #1（力度/表情），引脚 85（低 = 有手）
    input  wire        ir2_in,     // 红外 #2（弯音），引脚 73（低 = 有手）
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
        .key_valid (ttp_valid),
        .scan_start(ttp_scan_start)
    );
    wire ttp_scan_start;

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
    wire               note_valid_raw;
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
        .note_valid(note_valid_raw),
        .note_on   (note_on),
        .note_idx  (note_idx)
    );

    // ==================================================================
    // 延音踏板（Sustain）—— 2026-11-04
    //   IR#1（引脚 85）被遮挡 = 踩下延音踏板。
    //   踩下时抑制"松键"事件：note_alloc 收不到 note_off，声部保持 busy，
    //   piano_engine 就不会走 70 ms 的 damper，音符按自然衰减继续响。
    //   抬脚后事件恢复正常（已自然衰减完的音不会突然复活）。
    //   红外 gesture 实例保留（诊断用），但音色改由 UI 控制，不再被挥手夺走。
    // ==================================================================
    //   ui_sustain_en（下行 0xA5 0x03）是延音踏板的**总开关**：
    //   红外模块朝桌面/被常遮挡时会一直报"有手"= 踏板被永久踩住，
    //   数字波形档的松键事件会被全部吞掉（听感上就是"挂音"）。
    //   上位机关掉这个开关，sustain 恒 0，松键立刻释放。
    wire ui_sustain_en;                                         // 1 = 启用 IR#1 踏板
    wire sustain    = ir_hand & ui_sustain_en;                  // 消抖后的"有手"且踏板使能
    wire note_valid = note_valid_raw & (note_on | ~sustain);

    // 抬脚瞬间且没有任何键按着 → 清空所有声部，回收"延长音"占用的复音资源
    reg sustain_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sustain_d <= 1'b0;
        else        sustain_d <= sustain;
    end
    wire all_off = (sustain_d & ~sustain) & (key_state == {KEY_NUM{1'b0}});

    // ==================================================================
    // 5. 红外手势 → 音色切换（第二演奏维度）
    // ==================================================================
    wire [2:0] ir_wave;              // 红外维护的音色
    wire [2:0] ui_wave;              // 上位机指定的音色
    wire       ui_active;            // 1 = UI 在控，0 = 红外在控
    wire       ui_fade_soft;         // 1 = 松键渐弱，0 = 松键立即静音
    wire [2:0] wave_sel = ui_wave;   // 红外#1 改作延音踏板，音色只由 UI/默认值决定
    wire       ir_gesture_valid;
    wire       ir_hand;
    wire       swipe_tooshort;
    wire       swipe_toolong;

    ir_gesture #(
        .DEBOUNCE_CNT  (IR_DEBOUNCE_CNT),
        .MIN_SWIPE_CNT (IR_MIN_SWIPE_CNT),
        .MAX_SWIPE_CNT (IR_MAX_SWIPE_CNT),
        .INIT_SEL      (3'b100),         // 复位默认：钢琴
        .N_COLORS      (6)          // 三角/方波/锯齿/脉冲/钢琴/拨弦
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
    // 4b. 红外 #2（引脚 73，弯音通道）打两拍同步 + 两路状态打包
    //     模块 OUT 低有效，这里统一成"1 = 检测到手"，方便上位机直接显示。
    // ==================================================================
    reg [1:0] ir2_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ir2_sync <= 2'b11;      // 上电默认未遮挡
        else        ir2_sync <= {ir2_sync[0], ir2_in};
    end
    wire [1:0] ir_hand_both = {~ir2_sync[1], ir_hand};

    // ==================================================================
    // 4c. 红外诊断计数
    //     目的：让上位机直接看到"红外到底有没有反应"——
    //     ir_hand 反映当前有没有遮挡，三个计数分别记录有效挥手、
    //     过短被拒、过长被拒，能直接区分"没接好"和"阈值不合适"。
    // ==================================================================
    reg [7:0] ir_gest_cnt, ir_short_cnt, ir_long_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ir_gest_cnt  <= 8'd0;
            ir_short_cnt <= 8'd0;
            ir_long_cnt  <= 8'd0;
        end
        else begin
            if (ir_gesture_valid) ir_gest_cnt  <= ir_gest_cnt  + 8'd1;
            if (swipe_tooshort)   ir_short_cnt <= ir_short_cnt + 8'd1;
            if (swipe_toolong)    ir_long_cnt  <= ir_long_cnt  + 8'd1;
        end
    end

    // ==================================================================
    // 5b. 上位机下行命令（UI 实时切音色）
    //     硬件优先：挥手时 ui_cmd 的 clr_i 拉高，立刻交回红外控制
    // ==================================================================
    wire [7:0] ui_rx_data;
    wire       ui_rx_valid;

    uart_rx #(
        .CLK_HZ (27_000_000),
        .BAUD   (921_600)      // 必须与上行 uart_stream 一致，否则 UI 下行命令解不出来
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
        .fade_soft(ui_fade_soft),
        .sustain_en(ui_sustain_en),
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
        .NOTE_BITS  (NOTE_BITS),
        .USE_KS     (1)                // 钢琴档改用 Karplus-Strong 拨弦
    ) u_synth (
        .clk            (clk),
        .rst_n          (rst_n),
        .note_valid     (note_valid),
        .note_on        (note_on),
        .note_idx       (note_idx),
        .all_off        (all_off),
        .fade_soft      (ui_fade_soft),
        .sustain        (sustain),
        .key_state      (key_state),
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

    // ==================================================================
    // 6c. 演奏延迟统计（按键事件 → 开始发声）
    //     key_evt  : key_scan 的 note_valid 脉冲
    //     sound_evt: voice_busy 的上升沿（某个声部开始发声）
    // ==================================================================
    // 终点改用 note_valid（消抖完成，等价于"即将发声"）。
    //   之前用 voice_busy 上升沿，但钢琴/吉他有衰减尾巴，voice_busy
    //   会长期保持 1，导致只有第一次按键能触发测量 —— n 不再增长。
    wire sound_evt = note_valid;

    wire [31:0] lat_last, lat_min, lat_max, lat_sum;
    wire [15:0] lat_cnt;

    // 采用队友的 latency_meter：终点用"音频帧起点(LRCK 上升沿)"，
    // 而不是"消抖完成"——这样测出来的值包含帧对齐（0~19 µs 随机），
    // 不再是死板的恒定值。
    reg  lrck_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lrck_d <= 1'b0;
        else        lrck_d <= i2s_lrck;
    end
    wire frame_tick   = i2s_lrck & ~lrck_d;              // LRCK 上升沿

    // 起点必须是"有新的键按下"的那一次扫描，而不是"有键按着"的电平。
    //   旧写法 (|(~ttp_keys)) 在按住不放时每 20 ms 都会置 1，导致 t0 被反复
    //   刷新，下一个新键到来时拿一个很旧的 t0 去配对 —— 实测出现过 45 ms 的
    //   假延迟（HANDOFF §8.3 那条怀疑的真正原因）。
    //   TTP229 低有效：~ttp_keys = 1 表示该位按下。
    reg [15:0] ttp_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          ttp_prev <= 16'hFFFF;       // 上电默认全没按
        else if (ttp_valid)  ttp_prev <= ttp_keys;
    end
    wire new_press = ttp_valid && (|((~ttp_keys) & ttp_prev));
    wire touch_evt    = new_press;                       // 有新键按下
    wire note_on_evt  = note_valid & note_on;

    wire [255:0] hist_flat;
    wire [31:0]  scan_period;

    latency_meter #(
        .HIST_BINS (16),
        .BIN_SHIFT (16),
        .TIMEOUT   (1_350_000)
    ) u_lat (
        .clk         (clk),
        .rst_n       (rst_n),
        .touch_evt   (touch_evt),
        .note_on_evt (note_on_evt),
        .frame_tick  (frame_tick),
        .scan_tick   (ttp_valid),
        .lat_last    (lat_last),
        .lat_min     (lat_min),
        .lat_max     (lat_max),
        .lat_sum     (lat_sum),
        .lat_cnt     (lat_cnt),
        .hist_flat   (hist_flat),
        .scan_period (scan_period)
    );

    // hist_flat（256 位）拆成 16 个 16 位给 uart_stream
    wire [15:0] h0  = hist_flat[  0 +: 16];
    wire [15:0] h1  = hist_flat[ 16 +: 16];
    wire [15:0] h2  = hist_flat[ 32 +: 16];
    wire [15:0] h3  = hist_flat[ 48 +: 16];
    wire [15:0] h4  = hist_flat[ 64 +: 16];
    wire [15:0] h5  = hist_flat[ 80 +: 16];
    wire [15:0] h6  = hist_flat[ 96 +: 16];
    wire [15:0] h7  = hist_flat[112 +: 16];
    wire [15:0] h8  = hist_flat[128 +: 16];
    wire [15:0] h9  = hist_flat[144 +: 16];
    wire [15:0] h10 = hist_flat[160 +: 16];
    wire [15:0] h11 = hist_flat[176 +: 16];
    wire [15:0] h12 = hist_flat[192 +: 16];
    wire [15:0] h13 = hist_flat[208 +: 16];
    wire [15:0] h14 = hist_flat[224 +: 16];
    wire [15:0] h15 = hist_flat[240 +: 16];
    wire lat_valid = (lat_cnt != 16'd0);

    // ==================================================================
    // 6d. 12 音按键计数（替代没意义的延迟直方图，做演示统计）
    // ==================================================================
    reg [15:0] nc0, nc1, nc2, nc3, nc4, nc5;
    reg [15:0] nc6, nc7, nc8, nc9, nc10, nc11;

    // 用消抖后的 key_state 上升沿计数（不依赖 note_valid 的时序，
    // 上一版用 note_valid & note_on，被综合工具判成不可达，整个块被优化掉了）
    reg [KEY_NUM-1:0] key_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) key_prev <= {KEY_NUM{1'b0}};
        else        key_prev <= key_state;
    end
    wire [KEY_NUM-1:0] key_rise = key_state & ~key_prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nc0 <= 16'd0; nc1 <= 16'd0; nc2 <= 16'd0; nc3 <= 16'd0;
            nc4 <= 16'd0; nc5 <= 16'd0; nc6 <= 16'd0; nc7 <= 16'd0;
            nc8 <= 16'd0; nc9 <= 16'd0; nc10<= 16'd0; nc11<= 16'd0;
        end
        else begin
            if (key_rise[0])  nc0  <= nc0  + 16'd1;
            if (key_rise[1])  nc1  <= nc1  + 16'd1;
            if (key_rise[2])  nc2  <= nc2  + 16'd1;
            if (key_rise[3])  nc3  <= nc3  + 16'd1;
            if (key_rise[4])  nc4  <= nc4  + 16'd1;
            if (key_rise[5])  nc5  <= nc5  + 16'd1;
            if (key_rise[6])  nc6  <= nc6  + 16'd1;
            if (key_rise[7])  nc7  <= nc7  + 16'd1;
            if (key_rise[8])  nc8  <= nc8  + 16'd1;
            if (key_rise[9])  nc9  <= nc9  + 16'd1;
            if (key_rise[10]) nc10 <= nc10 + 16'd1;
            if (key_rise[11]) nc11 <= nc11 + 16'd1;
        end
    end

    // ------------------------------------------------------------------
    // 活跃声部数（真正的 popcount，不是"有没有声部忙"）
    //   旧写法 {2'b00, (|dbg_voice_busy)} 只发 1 位，上位机永远只看到 0/1，
    //   复音显示是假的。这里按 VOICE_NUM 参数化求和。
    // ------------------------------------------------------------------
    reg [2:0] voice_cnt;
    integer   vci;
    always @(*) begin
        voice_cnt = 3'd0;
        for (vci = 0; vci < VOICE_NUM; vci = vci + 1)
            voice_cnt = voice_cnt + {2'b00, dbg_voice_busy[vci]};
    end

    uart_stream #(
        .CLK_HZ (27_000_000),
        .BAUD   (921_600),      // CH340 上限档；BAUD_DIV=29，误差 +1.0%
        .DECIM  (1)             // 采样窗口 9.7 ms -> 帧率 ~103 fps（原 7/115200 -> 14.7 fps）
    ) u_uart (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_en  (i2s_sample_req),
        .audio      (i2s_audio_out),
        .keys       (key_state),
        .timbre     (wave_sel),
        .voices     (voice_cnt),
        .uart_tx    (uart_tx_line),
        .frame_busy (frame_busy),
        .lat_last   (lat_last),
        .lat_min    (lat_min),
        .lat_max    (lat_max),
        .lat_sum    (lat_sum),
        .lat_cnt    (lat_cnt),
        .lat_valid  (lat_valid),
        .hist0  (nc0),  .hist1  (nc1),  .hist2  (nc2),  .hist3  (nc3),
        .hist4  (nc4),  .hist5  (nc5),  .hist6  (nc6),  .hist7  (nc7),
        .hist8  (nc8),  .hist9  (nc9),  .hist10 (nc10), .hist11 (nc11),
        .hist12 (16'd0), .hist13 (16'd0), .hist14 (16'd0), .hist15 (16'd0),
        // 红外诊断（帧尾 568~571，供上位机显示"板子到底有没有收到红外"）
        .ir_hand        (ir_hand_both),
        .ir_gesture_cnt (ir_gest_cnt),
        .ir_short_cnt   (ir_short_cnt),
        .ir_long_cnt    (ir_long_cnt)
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
