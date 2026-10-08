// ============================================================================
//  模块名  : pwm.v
//  功能    : 可调占空比 PWM 发生器（带计数锁存，可在运行中改占空比）
//  说明    : 输出周期 = (PERIOD+1) 个时钟；高电平时间 = duty_cycle 个时钟。
//            该模块是小车电机调速、LED 调光的公共基础模块。
//  参数    : PERIOD  —— PWM 周期计数值。27MHz 下 PERIOD=27000 → 约 1kHz
//  作者    : 2026 FPGA 竞赛工程模板
// ============================================================================
module pwm #(
    parameter PERIOD = 27_000          // 27MHz / 27000 ≈ 1kHz
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] duty_cycle,     // 0 ~ PERIOD，0 = 常低，PERIOD = 常高
    output reg         pwm_out
);

    reg [31:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt     <= 32'd0;
            pwm_out <= 1'b0;
        end
        else begin
            if (cnt >= PERIOD) begin
                cnt <= 32'd0;
            end
            else begin
                cnt <= cnt + 32'd1;
            end

            // duty_cycle >= cnt+1 时输出高电平
            if (duty_cycle > cnt) begin
                pwm_out <= 1'b1;
            end
            else begin
                pwm_out <= 1'b0;
            end
        end
    end

endmodule
