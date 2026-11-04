// ============================================================================
//  模块名  : ui_cmd.v
//  功能    : 解析上位机下发的命令，输出"UI 指定音色"与"UI 是否在控"
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，27 MHz
//
//  ── 命令协议（3 字节，115200 8N1）──────────────────────────────────
//      0xA5  0x01  <wave>     设置音色，wave = 0..4
//      0xA5  0x02  <level>     （预留：静音/总音量，本版忽略）
//
//  ── 语义（方案 A：硬件优先）────────────────────────────────────────
//      ui_active = 1 表示"最近一次操作来自 UI"，此时音色用 ui_wave；
//      红外挥手会通过 clr_i 把 ui_active 清零 —— 挥手立刻夺回控制权。
//      这样"硬件（红外）优先"和"UI 也能实时切"两者不冲突。
// ============================================================================
`timescale 1ns / 1ps

module ui_cmd #(
    parameter CMD_MAGIC = 8'hA5,
    parameter CMD_WAVE  = 8'h01
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] rx_data,
    input  wire       rx_valid,
    input  wire       clr_i,        // 脉冲：交回红外控制（挥手时拉高）
    output reg  [2:0] ui_wave,      // UI 指定的音色
    output reg        fade_soft,    // 1 = 松键渐弱(48ms)，0 = 松键立即静音
    output reg        ui_active     // 1 = UI 在控，0 = 红外在控
);

    localparam S_MAGIC = 2'd0;
    localparam S_CMD   = 2'd1;
    localparam S_ARG   = 2'd2;

    reg [1:0] state;
    reg [7:0] cmd;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_MAGIC;
            cmd       <= 8'd0;
            ui_wave   <= 3'b100;      // 复位默认钢琴
            fade_soft <= 1'b1;        // 复位默认：松键渐弱
            ui_active <= 1'b0;        // 上电交给红外
        end
        else begin
            // 优先级：UI 最高（2026-11-03 用户要求改）
            //   旧逻辑里 clr_i（红外挥手）会把 ui_active 清零，结果是
            //   "UI 选了三角波，一按键（手在红外前晃）就跳回红外音色"。
            //   现在 UI 一旦下发过命令就锁住，红外不再能夺回控制权；
            //   只有复位才回到红外控制。
            //   注意：clr_i 端口保留是为了协议兼容与将来可选的"松手释放"，
            //   当前不参与任何逻辑。
            /*
            if (clr_i)
                ui_active <= 1'b0;
            */

            if (rx_valid) begin
                case (state)
                    S_MAGIC: begin
                        if (rx_data == CMD_MAGIC) state <= S_CMD;
                    end

                    S_CMD: begin
                        cmd   <= rx_data;
                        state <= S_ARG;
                    end

                    S_ARG: begin
                        // 只有"设置音色"命令且参数在 0..4 才接受
                        if (cmd == CMD_WAVE && rx_data <= 8'd5) begin   // 0~5：三角/方波/锯齿/脉冲/钢琴/吉他
                            ui_wave   <= rx_data[2:0];
                            ui_active <= 1'b1;
                        end
                        else if (cmd == 8'h02) begin                    // 渐弱开关
                            fade_soft <= (rx_data != 8'd0);
                            ui_active <= 1'b1;
                        end
                        state <= S_MAGIC;
                    end

                    default: state <= S_MAGIC;
                endcase
            end
        end
    end

endmodule
