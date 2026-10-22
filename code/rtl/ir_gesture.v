// ============================================================================
//  模块名  : ir_gesture.v
//  功能    : 红外避障模块 → 无接触"挥手"手势 → 音色切换（演奏第二维度）
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，主时钟 27 MHz
//
//  ── 硬件前提 ──────────────────────────────────────────────────────
//  红外避障模块（LM393，3.3V 供电）OUT → FPGA IO：
//      检测到前方有物体（约 2~30cm）时 OUT = 低电平
//      空闲时 OUT = 高电平
//  故 ir_in 为低有效，本模块内部用 debounce(ACTIVE_LOW=1) 归一化成
//  "hand = 1 表示检测到挥手"。
//
//  ── 手势判定（最小可用版）──────────────────────────────────────────
//  一次"有效挥手" = 手在传感器前停留 T，然后离开，且
//      TMIN <= T <= TMAX
//  每完成一次有效挥手，wave_sel 前进一档（0→1→2→3→4→0）：
//      000 三角 / 001 方波 / 010 锯齿 / 011 脉冲 25% / 100 钢琴
//  这样"音高（12 键）"与"音色（挥手）"构成两个独立可控的演奏维度。
//
//  ── 为什么这么定 ──────────────────────────────────────────────────
//  · 太短（< TMIN）：手快速掠过时 OUT 可能只是抖动/误触发，不算手势；
//  · 太长（> TMAX）：手一直放在传感器前属于"遮挡"而不是"挥手"，
//    也不该反复切音色；
//  · 停留时间在窗口内才认，是这个方案里最稳、也最容易在仿真里复现的判据。
//
//  ── 调试观察 ──────────────────────────────────────────────────────
//  hand_level    : 消抖后的"有手"电平，可直接点 LED 看传感器通不通
//  gesture_valid : 完成一次有效挥手的单周期脉冲
//  swipe_tooshort / swipe_toolong : 被拒的挥手，用于上板排查
//
//  ── 迭代空间（本期不做）───────────────────────────────────────────
//  进阶版可测两次挥手的时间间隔并映射成弯音（特雷门琴式），
//  但那需要改 synth_top 的频率控制字通路，侵入面大。
//
//  作者    : 第三代 beta.4（红外手势）
// ============================================================================
module ir_gesture #(
    parameter DEBOUNCE_CNT   = 540_000,      // 20 ms @27MHz
    parameter MIN_SWIPE_CNT  = 2_160_000,    // 80 ms
    parameter MAX_SWIPE_CNT  = 32_400_000,   // 1200 ms
    parameter INIT_SEL       = 3'd4,         // 复位默认：钢琴音色
    parameter N_COLORS       = 5             // 有效音色档数（0..4）
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ir_in,          // 来自避障模块：低 = 检测到物体
    output reg  [2:0] wave_sel,       // 当前音色，接 synth_top.wave_sel
    output reg        gesture_valid,  // 一次有效挥手完成（单周期脉冲）
    output wire       hand_level,     // 消抖后的手状态（1 = 有手）
    output reg        swipe_tooshort, // 挥手过短被拒（单周期脉冲）
    output reg        swipe_toolong   // 挥手过长被拒（单周期脉冲）
);

    // ==================================================================
    // 1. 消抖（复用现成模块）
    //    模块 OUT 低有效 → ACTIVE_LOW=1，消抖后 hand = 1 表示"有手"
    // ==================================================================
    wire hand;
    wire hand_press;          // 手刚进入（单周期），留作观察

    debounce #(
        .CNT_MAX    (DEBOUNCE_CNT),
        .ACTIVE_LOW (1)
    ) u_deb (
        .clk       (clk),
        .rst_n     (rst_n),
        .key_in    (ir_in),
        .key_state (hand),
        .key_press (hand_press)
    );

    assign hand_level = hand;

    // ==================================================================
    // 2. 手离开的下降沿：~hand & 上一拍 hand
    //    本拍里 hold_cnt 仍是"离开前"的值（它在下一个时钟沿才清零），
    //    所以组合比较 swipe_ok 必须与 hand_release 同拍判定。
    // ==================================================================
    reg hand_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) hand_d <= 1'b0;
        else        hand_d <= hand;
    end

    wire hand_release = (~hand) & hand_d;

    // ==================================================================
    // 3. 停留计时：只在"有手"期间累加，手离开即清零（饱和防溢出）
    // ==================================================================
    reg [31:0] hold_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hold_cnt <= 32'd0;
        end
        else if (hand) begin
            if (hold_cnt != 32'hFFFF_FFFF)
                hold_cnt <= hold_cnt + 32'd1;
        end
        else begin
            hold_cnt <= 32'd0;
        end
    end

    // ==================================================================
    // 4. 窗口判定
    // ==================================================================
    wire swipe_ok    = hand_release &&
                       (hold_cnt >= MIN_SWIPE_CNT) &&
                       (hold_cnt <= MAX_SWIPE_CNT);
    wire swipe_short = hand_release && (hold_cnt < MIN_SWIPE_CNT);
    wire swipe_long  = hand_release && (hold_cnt > MAX_SWIPE_CNT);

    // ==================================================================
    // 5. 音色档位推进（环形）与结果脉冲
    // ==================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wave_sel       <= INIT_SEL;
            gesture_valid  <= 1'b0;
            swipe_tooshort <= 1'b0;
            swipe_toolong  <= 1'b0;
        end
        else begin
            gesture_valid  <= 1'b0;
            swipe_tooshort <= 1'b0;
            swipe_toolong  <= 1'b0;

            if (swipe_ok) begin
                gesture_valid <= 1'b1;
                // 环形推进：到顶回到 0，保证 wave_sel 始终落在有效音色内
                if (wave_sel >= (N_COLORS - 1))
                    wave_sel <= 3'd0;
                else
                    wave_sel <= wave_sel + 3'd1;
            end
            else if (swipe_short) begin
                swipe_tooshort <= 1'b1;
            end
            else if (swipe_long) begin
                swipe_toolong <= 1'b1;
            end
        end
    end

endmodule
