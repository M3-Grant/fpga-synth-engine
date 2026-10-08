// ============================================================================
//  模块名  : clk_div.v
//  功能    : 时钟分频器 —— 产生周期性的单拍脉冲（tick）
//  说明    : 输出 tick 在时钟域内为单周期高电平，用于驱动"按秒/按毫秒"的逻辑。
//            不直接用分频后的时钟去驱动逻辑，避免生成额外的时钟域。
//  作者    : 2026 FPGA 竞赛工程模板
// ============================================================================
module clk_div #(
    parameter CNT_MAX = 27_000_000     // 27MHz 时钟下，计数到此值约为 1 秒
)(
    input  wire clk,        // 27MHz 板载时钟
    input  wire rst_n,      // 低电平复位
    output reg  tick        // 每 CNT_MAX+1 个时钟产生一个单周期高脉冲
);

    reg [31:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt  <= 32'd0;
            tick <= 1'b0;
        end
        else if (cnt >= CNT_MAX) begin
            cnt  <= 32'd0;
            tick <= 1'b1;
        end
        else begin
            cnt  <= cnt + 32'd1;
            tick <= 1'b0;
        end
    end

endmodule
