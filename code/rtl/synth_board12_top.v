// ============================================================================
//  模块名  : synth_board12_top.v
//  功能    : 12 键电子琴板级顶层 —— 可直接上板演奏
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，主时钟 27 MHz
//
//  ── 与 synth_board_top（2 键版）的区别 ────────────────────────────
//  2 键版：用状态机切换音阶，只能演示"逻辑通不通"
//  本版本：12 个按键各自对应一个音符，**能真正演奏**
//          12 键覆盖 C4~B4 一个完整八度（含全部半音）
//
//  ── 可演奏内容 ────────────────────────────────────────────────────
//      · 单音旋律（任意调式，因为半音齐全）
//      · 三和弦 / 七和弦（VOICE_NUM=4，最多四音同时）
//      · 简单双手配合
//
//  ── 按键器件 ──────────────────────────────────────────────────────
//  主用 TTP223 触摸模块（高电平有效，触摸=1）
//  也可用 6×6×5 微动开关（按接线调整 key_scan 的 ACTIVE_LOW）
//
//  ── LED 指示 ──────────────────────────────────────────────────────
//      led[0]   : 心跳闪烁（约 1.6Hz），证明逻辑在跑
//      led[1]   : 有音符在发声
//      led[2]   : 正在扫描/上报事件（调试用）
//
//  作者    : 第三代 beta3
// ============================================================================
module synth_board12_top #(
    parameter VOICE_NUM  = 4,
    parameter NOTE_BITS  = 5,
    parameter BCK_HALF   = 4,
    parameter KEY_NUM    = 12,
    parameter KEY_CNT_MAX= 270_000     // 消抖 10ms
)(
    input  wire               clk,        // 27 MHz，引脚 4
    input  wire [KEY_NUM-1:0] key,        // 12 路按键输入
    output wire               i2s_bck,    // 引脚 56
    output wire               i2s_lrck,   // 引脚 55
    output wire               i2s_din,    // 引脚 54
    output wire               pa_en,      // 引脚 51
    output wire [5:0]         led         // 引脚 15~20（低电平点亮）
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
    // 2. 12 路按键扫描 → 音符事件
    // ==================================================================
    wire [KEY_NUM-1:0] key_state;
    wire                note_valid;
    wire                note_on;
    wire [NOTE_BITS-1:0] note_idx;

    key_scan #(
        .KEY_NUM    (KEY_NUM),
        .CNT_MAX    (KEY_CNT_MAX),
        .ACTIVE_LOW (0),              // TTP223 默认高有效；微动开关改成 1
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
    // 3. 复音合成器
    // ==================================================================
    wire [VOICE_NUM-1:0] dbg_voice_busy;
    wire signed [15:0]   dbg_mix;

    synth_top #(
        .VOICE_NUM  (VOICE_NUM),
        .PHASE_BITS (32),
        .BCK_HALF   (BCK_HALF),
        .AMP        (16'sh1800),        // 3/16 满量程（三角波实测定档）
        .NOTE_BITS  (NOTE_BITS)
    ) u_synth (
        .clk            (clk),
        .rst_n          (rst_n),
        .note_valid     (note_valid),
        .note_on        (note_on),
        .note_idx       (note_idx),
        .i2s_bck        (i2s_bck),
        .i2s_lrck       (i2s_lrck),
        .i2s_din        (i2s_din),
        .dbg_voice_busy (dbg_voice_busy),
        .dbg_mix        (dbg_mix)
    );

    // ==================================================================
    // 4. 板载功放使能（常开）
    // ==================================================================
    assign pa_en = 1'b1;

    // ==================================================================
    // 5. LED 指示（低电平点亮）
    //    led[0] : 心跳
    //    led[1] : 有音符在发声
    //    led[2] : 正在上报事件（note_valid 太短，用 latch 展宽）
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
            // 事件灯展宽到约 0.2 秒，肉眼可见
            if (note_valid)                  evt_stretch <= 1'b1;
            else if (blink[22:0] == 23'd0)   evt_stretch <= 1'b0;
        end
    end

    wire any_busy = |dbg_voice_busy;

    // 1 = 点亮
    wire [5:0] led_on = {
        3'b000,          // [5:3] 预留
        evt_stretch,     // [2]   事件指示
        any_busy,        // [1]   正在发声
        blink[23]        // [0]   心跳
    };

    assign led = ~led_on;

endmodule
