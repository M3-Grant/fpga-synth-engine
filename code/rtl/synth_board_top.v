// ============================================================================
//  模块名  : synth_board_top.v
//  功能    : 板级顶层 —— 把真实按键接到复音合成器，可直接上板演奏
//  板卡    : Sipeed Tang Nano 20K (GW2AR-LV18QN88C8/I7)，主时钟 27 MHz
//
//  ── 为什么需要这一层 ──────────────────────────────────────────────
//  synth_top 的输入是抽象的音符事件（note_valid/note_on/note_idx），
//  板上没有东西能驱动它。本模块负责：
//      物理按键 → 消抖 → 音符事件 → synth_top → I2S → 板载功放
//
//  ── Tang Nano 20K 板载按键只有 2 个 ───────────────────────────────
//      KEY1 = 引脚 87
//      KEY2 = 引脚 88（与复位复用）
//  只有 2 个键弹不了曲子，所以本设计用「2 键 + 状态机」实现音阶步进：
//      KEY1 : 确认当前音（note-on / note-off 切换）
//      KEY2 : 切换到下一个音（C-D-E-F-G-A-B-C）
//  这样只用 2 个键就能验证「复音架构 + 包络」是否真的工作。
//
//  ── 要真正演奏需要更多键 ──────────────────────────────────────────
//  后续接 8 个触摸/按键到 40pin 扩展口，把 note_idx 换成按键编码即可。
//  本模块已经把接口留好（见 u_key 部分的注释）。
//
//  ── 上板现象 ──────────────────────────────────────────────────────
//      led[0]   : 1.6Hz 心跳闪烁（证明逻辑在跑）
//      led[1]   : 当前选中音符指示
//      led[2]   : 按键按下时亮
//      led[5:3] : 当前音阶位置（二进制）
//
//  作者    : 第二代迭代 03
// ============================================================================
module synth_board_top #(
    parameter VOICE_NUM  = 4,
    parameter NOTE_BITS  = 5,
    parameter BCK_HALF   = 4
)(
    input  wire        clk,        // 27 MHz，引脚 4
    input  wire        key1,       // 引脚 87
    input  wire        key2,       // 引脚 88
    output wire        i2s_bck,    // 引脚 56
    output wire        i2s_lrck,   // 引脚 55
    output wire        i2s_din,    // 引脚 54
    output wire        pa_en,      // 引脚 51
    output wire [5:0]  led         // 引脚 15~20（低电平点亮）
);

    // ==================================================================
    // 1. 上电复位（不依赖外部按键）
    //    27MHz 下 2^16 周期 ≈ 2.4 ms
    // ==================================================================
    reg [15:0] por_cnt = 16'd0;
    reg        rst_n   = 1'b0;

    always @(posedge clk) begin
        if (&por_cnt) rst_n <= 1'b1;
        else          por_cnt <= por_cnt + 16'd1;
    end

    // ==================================================================
    // 2. 按键消抖（板载按键按下为高电平 → ACTIVE_LOW = 0）
    // ==================================================================
    wire key1_state, key1_press;
    wire key2_state, key2_press;

    debounce #(
        .CNT_MAX    (270_000),    // 27MHz 下约 10ms
        .ACTIVE_LOW (0)
    ) u_db1 (
        .clk       (clk),
        .rst_n     (rst_n),
        .key_in    (key1),
        .key_state (key1_state),
        .key_press (key1_press)
    );

    debounce #(
        .CNT_MAX    (270_000),
        .ACTIVE_LOW (0)
    ) u_db2 (
        .clk       (clk),
        .rst_n     (rst_n),
        .key_in    (key2),
        .key_state (key2_state),
        .key_press (key2_press)
    );

    // ==================================================================
    // 3. 音阶表：C4 ~ C5（8 个音，对应 note_table 的索引）
    //    note_table 的索引 0 = C4，每 +1 是一个半音
    // ==================================================================
    reg [2:0] scale_pos;      // 0~7，当前在第几个音
    reg       note_active;    // 当前是否在发声

    // C大调音阶在 note_table 中的索引：C(0) D(2) E(4) F(5) G(7) A(9) B(11) C(12)
    reg [NOTE_BITS-1:0] scale_note;

    always @(*) begin
        case (scale_pos)
            3'd0: scale_note = 5'd0;    // C4
            3'd1: scale_note = 5'd2;    // D4
            3'd2: scale_note = 5'd4;    // E4
            3'd3: scale_note = 5'd5;    // F4
            3'd4: scale_note = 5'd7;    // G4
            3'd5: scale_note = 5'd9;    // A4
            3'd6: scale_note = 5'd11;   // B4
            default: scale_note = 5'd12; // C5
        endcase
    end

    // ==================================================================
    // 4. 按键 → 音符事件
    //    KEY2 : 切换音阶位置（松开发声时才能切，避免卡音）
    //    KEY1 : 按下发声 / 松开停声
    // ==================================================================
    reg        note_valid_r;
    reg        note_on_r;
    reg [NOTE_BITS-1:0] note_idx_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scale_pos    <= 3'd0;
            note_active  <= 1'b0;
            note_valid_r <= 1'b0;
            note_on_r    <= 1'b0;
            note_idx_r   <= 5'd0;
        end
        else begin
            note_valid_r <= 1'b0;      // 默认无事件

            // ---- KEY2：切换音阶 ----
            if (key2_press && !note_active) begin
                scale_pos <= scale_pos + 3'd1;   // 3 位自然回绕 7→0
            end

            // ---- KEY1：发声 / 停声 ----
            if (key1_press) begin
                note_valid_r <= 1'b1;
                note_idx_r   <= scale_note;
                if (note_active) begin
                    note_on_r   <= 1'b0;         // 已经在响 → 停
                    note_active <= 1'b0;
                end
                else begin
                    note_on_r   <= 1'b1;         // 没响 → 开始
                    note_active <= 1'b1;
                end
            end
        end
    end

    // ==================================================================
    // 5. 复音合成器
    // ==================================================================
    wire [VOICE_NUM-1:0] dbg_voice_busy;
    wire signed [15:0]   dbg_mix;

    synth_top #(
        .VOICE_NUM  (VOICE_NUM),
        .PHASE_BITS (32),
        .BCK_HALF   (BCK_HALF),
        .AMP        (16'sh2000),
        .NOTE_BITS  (NOTE_BITS)
    ) u_synth (
        .clk            (clk),
        .rst_n          (rst_n),
        .note_valid     (note_valid_r),
        .note_on        (note_on_r),
        .note_idx       (note_idx_r),
        .i2s_bck        (i2s_bck),
        .i2s_lrck       (i2s_lrck),
        .i2s_din        (i2s_din),
        .dbg_voice_busy (dbg_voice_busy),
        .dbg_mix        (dbg_mix)
    );

    // ==================================================================
    // 6. 板载功放使能（常开）
    // ==================================================================
    assign pa_en = 1'b1;

    // ==================================================================
    // 7. LED 指示（低电平点亮，所以整体取反）
    //    led[0]   : 心跳，约 1.6Hz
    //    led[1]   : 有音符在发声
    //    led[5:3] : 当前音阶位置
    // ==================================================================
    reg [23:0] blink;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) blink <= 24'd0;
        else        blink <= blink + 24'd1;
    end

    // 1 = 点亮
    wire [5:0] led_on = {
        scale_pos,               // [5:3] 音阶位置
        2'b00,                   // [2]   预留（按键指示并入 heartbeat）
        note_active,             // [1]   正在发声
        blink[23]                // [0]   心跳
    };

    assign led = ~led_on;

endmodule
