// ============================================================================
//  模块名  : chord_demo_top.v
//  功能    : 【自动演示 + 音准标定】上电自动循环播放，**无需任何接线**
//
//  用途    :
//      1. 验证复音混合 —— 和弦能不能同时响、会不会互相干扰
//      2. 标定音准     —— 每个音持续 0.5~1.5 秒，方便用手机调音器测量
//      3. 验证音量     —— AMP 已从 1/4 降到 1/16（-12dB）
//
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，主时钟 27 MHz
//  引脚    : 与 tone_test_top 完全一致 → **直接复用 tone_test.cst**
//            clk=4, i2s_din=54, i2s_lrck=55, i2s_bck=56, pa_en=51, led=15~20
//
//  ── 播放时间轴（一轮 15 秒，循环）──────────────────────────────────
//      1.0s ~ 2.5s   C4 单音                      ← 测 261.6 Hz
//      3.5s ~ 5.0s   C4 + E4 + G4     大三和弦     ← 测复音（3 声部）
//      6.0s ~ 7.5s   C4 + E4 + G4 + B4 大七和弦    ← 测复音（4 声部满）
//      8.5s ~12.5s   音阶上行 C4 D4 E4 F4 G4 A4 B4 C5（每音 0.5s）
//     12.5s ~15.0s   静音
//
//  ── 手机上怎么看 ──────────────────────────────────────────────────
//      音阶段每个音持续 0.5 秒，调音器 App 应该依次显示
//      C4 D4 E4 F4 G4 A4 B4 C5（对应 261.6 / 293.7 / 329.6 / 349.2 /
//      392.0 / 440.0 / 493.9 / 523.3 Hz）
//
//  ── LED 指示 ──────────────────────────────────────────────────────
//      led[5:3] : 当前占用的声部数（0~4），和弦时应该跳到 3 或 4
//      led[1]   : 有音在发声
//      led[0]   : 心跳（约 1.6 Hz）
//
//  作者    : 第四代迭代 —— 自动演示/标定版
// ============================================================================
module chord_demo_top #(
    parameter VOICE_NUM = 4,
    parameter NOTE_BITS = 5,
    parameter BCK_HALF  = 4,
    parameter AMP       = 16'sh1000,   // 1/8 满量程（实测定档：昨天的 1/2，比 1/16 大一倍）
    parameter TICK_MAX  = 16'd15000    // 一轮 15000 ms = 15 秒
)(
    input  wire        clk,        // 27 MHz，引脚 4
    output wire        i2s_bck,    // 引脚 56
    output wire        i2s_lrck,   // 引脚 55
    output wire        i2s_din,    // 引脚 54
    output wire        pa_en,      // 引脚 51
    output wire [5:0]  led         // 引脚 15~20（低电平点亮）
);

    // ==================================================================
    // 1. 上电复位（不依赖外部按键）
    // ==================================================================
    reg [15:0] por_cnt = 16'd0;
    reg        rst_n   = 1'b0;

    always @(posedge clk) begin
        if (&por_cnt) rst_n <= 1'b1;
        else          por_cnt <= por_cnt + 16'd1;
    end

    // ==================================================================
    // 2. 1 ms 时基 → tick（单位 ms，0 ~ TICK_MAX 循环）
    //    27 MHz / 27000 = 1 kHz
    // ==================================================================
    localparam [15:0] MS_MAX = 16'd26999;      // 27000 - 1

    reg [15:0] ms_cnt = 16'd0;
    reg [15:0] tick   = 16'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ms_cnt <= 16'd0;
            tick   <= 16'd0;
        end
        else if (ms_cnt == MS_MAX) begin
            ms_cnt <= 16'd0;
            tick   <= (tick >= TICK_MAX) ? 16'd0 : tick + 16'd1;
        end
        else begin
            ms_cnt <= ms_cnt + 16'd1;
        end
    end

    // 刚跨入新 tick 的那一个时钟周期
    wire evt_strobe = (ms_cnt == 16'd0);

    // ==================================================================
    // 3. 音符编号（note_table 索引：0=C4，每 +1 一个半音）
    // ==================================================================
    localparam [4:0] N_C4 = 5'd0,  N_D4 = 5'd2,  N_E4 = 5'd4,  N_F4 = 5'd5;
    localparam [4:0] N_G4 = 5'd7,  N_A4 = 5'd9,  N_B4 = 5'd11, N_C5 = 5'd12;

    // ==================================================================
    // 4. 事件时间表
    //    同一个 tick 只能发一个事件，所以和弦的各个音排在连续 tick 上
    //    （相邻 1 ms，人耳完全听不出先后）
    // ==================================================================
    reg                 evt_valid;
    reg                 evt_on;
    reg [NOTE_BITS-1:0] evt_idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            evt_valid <= 1'b0;
            evt_on    <= 1'b1;
            evt_idx   <= 5'd0;
        end
        else begin
            evt_valid <= 1'b0;          // 默认：无事件（单周期脉冲）
            if (evt_strobe) begin
                case (tick)
                    // ---------- C4 单音 ----------
                    16'd1000: begin evt_valid <= 1'b1; evt_on <= 1'b1; evt_idx <= N_C4; end
                    16'd2500: begin evt_valid <= 1'b1; evt_on <= 1'b0; evt_idx <= N_C4; end

                    // ---------- 大三和弦 C4 + E4 + G4 ----------
                    16'd3500: begin evt_valid <= 1'b1; evt_on <= 1'b1; evt_idx <= N_C4; end
                    16'd3501: begin evt_valid <= 1'b1; evt_on <= 1'b1; evt_idx <= N_E4; end
                    16'd3502: begin evt_valid <= 1'b1; evt_on <= 1'b1; evt_idx <= N_G4; end
                    16'd5000: begin evt_valid <= 1'b1; evt_on <= 1'b0; evt_idx <= N_C4; end
                    16'd5001: begin evt_valid <= 1'b1; evt_on <= 1'b0; evt_idx <= N_E4; end
                    16'd5002: begin evt_valid <= 1'b1; evt_on <= 1'b0; evt_idx <= N_G4; end

                    // ---------- 大七和弦 C4 + E4 + G4 + B4（声部打满）----------
                    16'd6000: begin evt_valid <= 1'b1; evt_on <= 1'b1; evt_idx <= N_C4; end
                    16'd6001: begin evt_valid <= 1'b1; evt_on <= 1'b1; evt_idx <= N_E4; end
                    16'd6002: begin evt_valid <= 1'b1; evt_on <= 1'b1; evt_idx <= N_G4; end
                    16'd6003: begin evt_valid <= 1'b1; evt_on <= 1'b1; evt_idx <= N_B4; end
                    16'd7500: begin evt_valid <= 1'b1; evt_on <= 1'b0; evt_idx <= N_C4; end
                    16'd7501: begin evt_valid <= 1'b1; evt_on <= 1'b0; evt_idx <= N_E4; end
                    16'd7502: begin evt_valid <= 1'b1; evt_on <= 1'b0; evt_idx <= N_G4; end
                    16'd7503: begin evt_valid <= 1'b1; evt_on <= 1'b0; evt_idx <= N_B4; end

                    // ---------- 音阶上行（每个音 0.5 秒，方便测音准）----------
                    16'd8500 : begin evt_valid <= 1'b1; evt_on <= 1'b1; evt_idx <= N_C4; end
                    16'd9000 : begin evt_valid <= 1'b1; evt_on <= 1'b0; evt_idx <= N_C4; end
                    16'd9001 : begin evt_valid <= 1'b1; evt_on <= 1'b1; evt_idx <= N_D4; end
                    16'd9500 : begin evt_valid <= 1'b1; evt_on <= 1'b0; evt_idx <= N_D4; end
                    16'd9501 : begin evt_valid <= 1'b1; evt_on <= 1'b1; evt_idx <= N_E4; end
                    16'd10000: begin evt_valid <= 1'b1; evt_on <= 1'b0; evt_idx <= N_E4; end
                    16'd10001: begin evt_valid <= 1'b1; evt_on <= 1'b1; evt_idx <= N_F4; end
                    16'd10500: begin evt_valid <= 1'b1; evt_on <= 1'b0; evt_idx <= N_F4; end
                    16'd10501: begin evt_valid <= 1'b1; evt_on <= 1'b1; evt_idx <= N_G4; end
                    16'd11000: begin evt_valid <= 1'b1; evt_on <= 1'b0; evt_idx <= N_G4; end
                    16'd11001: begin evt_valid <= 1'b1; evt_on <= 1'b1; evt_idx <= N_A4; end
                    16'd11500: begin evt_valid <= 1'b1; evt_on <= 1'b0; evt_idx <= N_A4; end
                    16'd11501: begin evt_valid <= 1'b1; evt_on <= 1'b1; evt_idx <= N_B4; end
                    16'd12000: begin evt_valid <= 1'b1; evt_on <= 1'b0; evt_idx <= N_B4; end
                    16'd12001: begin evt_valid <= 1'b1; evt_on <= 1'b1; evt_idx <= N_C5; end
                    16'd12500: begin evt_valid <= 1'b1; evt_on <= 1'b0; evt_idx <= N_C5; end

                    default: ;   // 其余时间静音
                endcase
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
        .AMP        (AMP),
        .NOTE_BITS  (NOTE_BITS)
    ) u_synth (
        .clk            (clk),
        .rst_n          (rst_n),
        .note_valid     (evt_valid),
        .note_on        (evt_on),
        .note_idx       (evt_idx),
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
    // 7. LED：心跳 + 发声指示 + 当前声部数
    //    和弦时 led[5:3] 应跳到 3（三和弦）或 4（七和弦）
    // ==================================================================
    reg [23:0] blink;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) blink <= 24'd0;
        else        blink <= blink + 24'd1;
    end

    wire any_busy = |dbg_voice_busy;

    // 统计当前占用的声部数（0 ~ VOICE_NUM）
    reg [2:0] vcnt;
    integer   vi;
    always @(*) begin
        vcnt = 3'd0;
        for (vi = 0; vi < VOICE_NUM; vi = vi + 1)
            vcnt = vcnt + {2'b00, dbg_voice_busy[vi]};
    end

    // 1 = 点亮（板载 LED 低电平点亮，所以最后取反）
    assign led = ~{ vcnt, 1'b0, any_busy, blink[23] };

endmodule
