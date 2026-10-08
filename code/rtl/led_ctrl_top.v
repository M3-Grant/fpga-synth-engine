// ============================================================================
//  模块名  : led_ctrl_top.v
//  功能    : 多模式 LED 显示控制器（省赛作品 / 工程模板顶层）
//  按键    : KEY1（引脚 87）循环切换模式，共 5 种模式
//              模式0 流水灯    —— 6 个 LED 依次点亮（慢速）
//              模式1 呼吸灯    —— 6 个 LED 同步渐亮渐暗
//              模式2 闪烁      —— 6 个 LED 同步闪烁（快速）
//              模式3 跑马灯    —— 单个 LED 循环移动（快速）
//              模式4 全灭      —— 演示"停止"状态
//  板卡    : Sipeed Tang Nano 20K (GW2AR-LV18QN88C8/I7)
//  注意    : 板载 LED 为低电平点亮，因此输出取反
//  时钟    : 27MHz（引脚 4）
// ============================================================================
module led_ctrl_top #(
    // 时基参数：上板时保持默认值（真实时间）；仿真时把 FAST_SIM 置 1 可大幅缩短仿真时间
    parameter FAST_SIM = 0
)(
    input  wire       clk,        // 27MHz 板载时钟
    input  wire       rst_n,      // 复位按键（引脚 88，按下为高电平，此处低有效）
    input  wire       key,        // 模式切换按键（引脚 87，按下为高电平）
    output wire [5:0] led         // 6 个 LED（引脚 15~20，低电平点亮）
);

    // 根据仿真/上板选择时基
    localparam CNT_SLOW      = FAST_SIM ? 32'd9      : 32'd13_500_000;  // 慢节拍
    localparam CNT_FAST      = FAST_SIM ? 32'd3      : 32'd2_700_000;   // 快节拍
    localparam CNT_BLINK_HALF= FAST_SIM ? 32'd4      : 32'd2_699_999;   // 闪烁半周期
    localparam CNT_DEBOUNCE  = FAST_SIM ? 32'd4      : 32'd270_000;     // 消抖时间

    // ------------------------------------------------------------------
    // 1. 按键消抖（板载按键按下为高电平，故 ACTIVE_LOW = 0）
    // ------------------------------------------------------------------
    wire key_state;
    wire key_press;

    debounce #(
        .CNT_MAX    (CNT_DEBOUNCE),    // 上板约 10ms
        .ACTIVE_LOW (0)
    ) u_debounce (
        .clk       (clk),
        .rst_n     (rst_n),
        .key_in    (key),
        .key_state (key_state),
        .key_press (key_press)
    );

    // ------------------------------------------------------------------
    // 2. 节拍脉冲：慢节拍 0.5s，快节拍 0.1s
    // ------------------------------------------------------------------
    wire tick_slow;
    wire tick_fast;

    clk_div #(.CNT_MAX (CNT_SLOW)) u_tick_slow (   // 上板 0.5s
        .clk   (clk),
        .rst_n (rst_n),
        .tick  (tick_slow)
    );

    clk_div #(.CNT_MAX (CNT_FAST)) u_tick_fast (    // 上板 0.1s
        .clk   (clk),
        .rst_n (rst_n),
        .tick  (tick_fast)
    );

    // ------------------------------------------------------------------
    // 2b. 闪烁方波：占空比 50%，周期 0.2s（5Hz，人眼观察明显）
    //     注意：不能直接用 tick_fast，因为 tick 只是单周期脉冲，太短看不见
    // ------------------------------------------------------------------
    reg [31:0] blink_cnt;
    reg        blink_level;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blink_cnt   <= 32'd0;
            blink_level <= 1'b0;
        end
        else if (blink_cnt >= CNT_BLINK_HALF) begin   // 半周期翻转一次
            blink_cnt   <= 32'd0;
            blink_level <= ~blink_level;
        end
        else begin
            blink_cnt <= blink_cnt + 32'd1;
        end
    end

    // ------------------------------------------------------------------
    // 3. 模式计数器：每按一次键，模式 +1，到 4 后回到 0
    // ------------------------------------------------------------------
    reg [2:0] mode;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode <= 3'd0;
        end
        else if (key_press) begin
            if (mode >= 3'd4)
                mode <= 3'd0;
            else
                mode <= mode + 3'd1;
        end
    end

    // ------------------------------------------------------------------
    // 4. 呼吸灯用的占空比：先增后减，范围 0 ~ 200
    // ------------------------------------------------------------------
    reg [7:0]  breath_duty;
    reg        breath_dir;      // 0 = 递增，1 = 递减

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            breath_duty <= 8'd0;
            breath_dir  <= 1'b0;
        end
        else if (tick_fast) begin
            if (!breath_dir) begin
                if (breath_duty >= 8'd200) begin
                    breath_duty <= 8'd200;
                    breath_dir  <= 1'b1;
                end
                else begin
                    breath_duty <= breath_duty + 8'd5;
                end
            end
            else begin
                if (breath_duty <= 8'd5) begin
                    breath_duty <= 8'd0;
                    breath_dir  <= 1'b0;
                end
                else begin
                    breath_duty <= breath_duty - 8'd5;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // 5. 各模式的显示图案
    // ------------------------------------------------------------------
    reg [5:0] pat_flow;      // 流水灯
    reg [5:0] pat_marquee;   // 跑马灯

    // 流水灯：慢节拍下循环左移
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pat_flow <= 6'b000001;
        else if (tick_slow)
            pat_flow <= {pat_flow[4:0], pat_flow[5]};
    end

    // 跑马灯：快节拍下循环左移
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pat_marquee <= 6'b000001;
        else if (tick_fast)
            pat_marquee <= {pat_marquee[4:0], pat_marquee[5]};
    end

    // ------------------------------------------------------------------
    // 6. 呼吸灯 PWM：周期 200，占空比由 breath_duty 控制
    // ------------------------------------------------------------------
    wire pwm_breath;

    pwm #(.PERIOD (200)) u_pwm_breath (
        .clk       (clk),
        .rst_n     (rst_n),
        .duty_cycle({24'd0, breath_duty}),
        .pwm_out   (pwm_breath)
    );

    // ------------------------------------------------------------------
    // 7. 按模式选择输出图案
    // ------------------------------------------------------------------
    reg [5:0] led_on;        // 1 表示点亮

    always @(*) begin
        case (mode)
            3'd0:    led_on = pat_flow;                        // 流水灯
            3'd1:    led_on = {6{pwm_breath}};                 // 呼吸灯
            3'd2:    led_on = {6{blink_level}};                // 闪烁
            3'd3:    led_on = pat_marquee;                     // 跑马灯
            default: led_on = 6'b000000;                       // 全灭
        endcase
    end

    // 板载 LED 低电平点亮，取反输出
    assign led = ~led_on;

endmodule
