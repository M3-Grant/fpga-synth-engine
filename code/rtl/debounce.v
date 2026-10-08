// ============================================================================
//  模块名  : debounce.v
//  功能    : 按键消抖 + 边沿检测
//  说明    : 机械按键在按下/松开瞬间会有 10~20ms 的抖动，直接采样会导致
//            一次按键被识别成多次。本模块用计数器连续采样，只在电平稳定
//            一段时间后才更新输出，并额外给出"按下瞬间"的单周期脉冲。
//  参数    : CNT_MAX  —— 消抖时间对应的时钟数（27MHz 下 270000 ≈ 10ms）
//            ACTIVE_LOW —— 1 表示按键按下时为低电平
//  作者    : 2026 FPGA 竞赛工程模板
// ============================================================================
module debounce #(
    parameter CNT_MAX    = 270_000,    // 27MHz 下约 10ms
    parameter ACTIVE_LOW = 0
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key_in,      // 原始按键输入
    output reg  key_state,   // 消抖后的稳定电平（已按极性归一化：1 = 按下）
    output reg  key_press    // 按下瞬间的单周期脉冲（1 = 刚按下）
);

    reg        key_sync0, key_sync1;   // 两级同步，防止亚稳态
    reg [31:0] cnt;
    reg        key_state_d;            // 用于检测上升沿

    // ---- 输入同步 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_sync0 <= 1'b0;
            key_sync1 <= 1'b0;
        end
        else begin
            key_sync0 <= key_in;
            key_sync1 <= key_sync0;
        end
    end

    // ---- 极性归一化：把"按下"统一成 1 ----
    wire key_pressed_level = ACTIVE_LOW ? ~key_sync1 : key_sync1;

    // ---- 计数器：连续稳定一段时间才认定状态变化 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt       <= 32'd0;
            key_state <= 1'b0;
        end
        else if (key_pressed_level != key_state) begin
            if (cnt >= CNT_MAX) begin
                cnt       <= 32'd0;
                key_state <= key_pressed_level;
            end
            else begin
                cnt <= cnt + 32'd1;
            end
        end
        else begin
            cnt <= 32'd0;      // 电平与当前状态一致，计数清零
        end
    end

    // ---- 上升沿检测：输出"刚按下"的单周期脉冲 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_state_d <= 1'b0;
            key_press   <= 1'b0;
        end
        else begin
            key_state_d <= key_state;
            key_press   <= key_state & ~key_state_d;
        end
    end

endmodule
