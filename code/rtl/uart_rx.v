// ============================================================================
//  模块名  : uart_rx.v
//  功能    : 串口接收（8N1），给上位机下发的命令用
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，27 MHz
//
//  ── 为什么需要它 ──────────────────────────────────────────────────
//  上位机 synth_viz.py 原本只能"看"（FPGA → PC 单向 576 字节帧），
//  不能"控"。本模块补上 PC → FPGA 的接收方向，让 UI 能实时切音色。
//
//  ── 接线 ──────────────────────────────────────────────────────────
//      USB-TTL 的 TXD  → FPGA 引脚 70（RX 输入）
//      USB-TTL 的 RXD  → FPGA 引脚 48（TX 输出，uart_stream 用）
//      GND 共地
//  注意：TX/RX 是交叉的，别接成 TXD-TXD。
// ============================================================================
`timescale 1ns / 1ps

module uart_rx #(
    parameter CLK_HZ = 27_000_000,
    parameter BAUD   = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,          // 来自 USB-TTL 的 TXD
    output reg  [7:0] data,        // 收到的字节
    output reg        valid        // 单周期脉冲（收到一个完整字节）
);

    localparam BAUD_DIV = CLK_HZ / BAUD;   // 234 @27MHz

    // 两级同步，消除亚稳态
    reg rx_d0, rx_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_d0 <= 1'b1;
            rx_d1 <= 1'b1;
        end
        else begin
            rx_d0 <= rx;
            rx_d1 <= rx_d0;
        end
    end

    localparam S_IDLE = 2'd0;
    localparam S_START = 2'd1;   // 起始位中点对齐
    localparam S_DATA  = 2'd2;   // 采 8 位
    localparam S_STOP  = 2'd3;   // 停止位

    reg [1:0]  state;
    reg [15:0] cnt;
    reg [2:0]  bit_i;
    reg [7:0]  shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            cnt   <= 16'd0;
            bit_i <= 3'd0;
            shift <= 8'd0;
            data  <= 8'd0;
            valid <= 1'b0;
        end
        else begin
            valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    // 检测到起始位（下降沿到 0）
                    if (!rx_d1) begin
                        cnt   <= 16'd0;
                        state <= S_START;
                    end
                end

                // 等到起始位中点再确认（抗毛刺）
                S_START: begin
                    if (cnt == (BAUD_DIV / 2)) begin
                        cnt <= 16'd0;
                        if (!rx_d1) begin
                            bit_i <= 3'd0;
                            state <= S_DATA;
                        end
                        else begin
                            state <= S_IDLE;      // 假起始位，丢弃
                        end
                    end
                    else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                // 每 BAUD_DIV 采一位，LSB first
                S_DATA: begin
                    if (cnt == BAUD_DIV - 1) begin
                        cnt   <= 16'd0;
                        shift <= {rx_d1, shift[7:1]};
                        if (bit_i == 3'd7) state <= S_STOP;
                        else               bit_i <= bit_i + 3'd1;
                    end
                    else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                // 停止位：确认高电平后输出
                S_STOP: begin
                    if (cnt == BAUD_DIV - 1) begin
                        cnt   <= 16'd0;
                        data  <= shift;
                        valid <= 1'b1;
                        state <= S_IDLE;
                    end
                    else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
