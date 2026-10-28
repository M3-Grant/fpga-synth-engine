// ============================================================================
//  模块名  : ttp229_scan.v
//  功能    : TTP229 电容触摸模块的 2 线串行读出 → 并行键状态
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，27 MHz
//
//  ── 硬件说明（重要）──────────────────────────────────────────────
//  市面上的"TTP229 钢琴模块"（99×35 mm、5P 排针）**不是标准 I2C**，
//  虽然商品页写 I2C，但引脚是：
//      VCC   3.3~5.5V（本工程接 3.3V，保证 IO 电平匹配）
//      GND
//      SCL   主机 → 模块：读时钟（由本模块产生）
//      SDO   模块 → 主机：数据位（MSB first，1 = 该键被触摸）
//      RGB   模块自带 RGB 灯的使能（本工程不用，悬空）
//
//  ── 时序（TTP229 datasheet）──────────────────────────────────────
//      ① 空闲：SCL = 高
//      ② 同步：SCL 拉低保持 > 100 µs（唤醒芯片）
//      ③ 读数：连续 KEY_NUM 个时钟脉冲，每个脉冲
//              SCL 高 SCL_HALF → SCL 低 SCL_HALF，
//              模块在 SCL **下降沿**更新 SDO，
//              本模块在 SCL 低电平末尾采样（最稳）
//      ④ 读完：SCL 回高，等 GAP_CNT 再扫下一轮
//
//  ── 位序 ──────────────────────────────────────────────────────────
//  模块把第一个时钟对应的键放在数据的最高位（MSB first）。
//  若实测发现顺序反了，把参数 MSB_FIRST 置 0 即可，不用改代码。
//
//  ── 一次扫描耗时 ──────────────────────────────────────────────────
//  GAP 20 ms + 同步 0.2 ms + 16×2 µs ≈ 20.2 ms
//  即键状态刷新率约 50 Hz，对演奏完全够（远快于人耳可辨的按键延迟）。
//
//  ── 与 key_scan.v 的关系 ──────────────────────────────────────────
//  key_scan.v 接收的是"12 位并行电平"，本模块输出"KEY_NUM 位并行电平"，
//  两者可以直接对接 —— TTP229 只是把 12 根线换成了 2 根，下游逻辑不变。
// ============================================================================
`timescale 1ns / 1ps

module ttp229_scan #(
    parameter KEY_NUM   = 16,          // 模块实际键数（12 键模块也填 16，多出的恒 0）
    parameter SYNC_CNT  = 5_400,       // 同步低电平 200 µs @27MHz
    parameter SCL_HALF  = 27,          // SCL 半周期 1 µs → 500 kHz
    parameter GAP_CNT   = 540_000,     // 扫描间隔 20 ms
    parameter MSB_FIRST = 1            // 1 = 第一位在最高位
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 sdo,        // 来自模块的数据位
    output reg                  scl,        // 送往模块的读时钟
    output reg  [KEY_NUM-1:0]   key_state,  // 1 = 该键被触摸
    output reg                  key_valid   // 一轮读数完成的单周期脉冲
);

    localparam S_IDLE = 3'd0;
    localparam S_SYNC = 3'd1;
    localparam S_CLKH = 3'd2;
    localparam S_CLKL = 3'd3;
    localparam S_DONE = 3'd4;

    reg [2:0]          state;
    reg [23:0]         cnt;
    reg [4:0]          bit_i;
    reg [KEY_NUM-1:0]  shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            cnt       <= 24'd0;
            bit_i     <= 5'd0;
            shift     <= {KEY_NUM{1'b0}};
            scl       <= 1'b1;
            key_state <= {KEY_NUM{1'b0}};
            key_valid <= 1'b0;
        end
        else begin
            key_valid <= 1'b0;

            case (state)
                // ---- 空闲：SCL 高，等待扫描间隔 ----
                S_IDLE: begin
                    scl <= 1'b1;
                    if (cnt >= GAP_CNT) begin
                        cnt   <= 24'd0;
                        state <= S_SYNC;
                    end
                    else cnt <= cnt + 24'd1;
                end

                // ---- 同步：SCL 拉低保持 200 µs ----
                S_SYNC: begin
                    scl <= 1'b0;
                    if (cnt >= SYNC_CNT) begin
                        cnt   <= 24'd0;
                        bit_i <= 5'd0;
                        state <= S_CLKH;
                    end
                    else cnt <= cnt + 24'd1;
                end

                // ---- 时钟高电平 ----
                S_CLKH: begin
                    scl <= 1'b1;
                    if (cnt >= SCL_HALF) begin
                        cnt   <= 24'd0;
                        state <= S_CLKL;
                    end
                    else cnt <= cnt + 24'd1;
                end

                // ---- 时钟低电平：末尾采样 SDO ----
                S_CLKL: begin
                    scl <= 1'b0;
                    if (cnt >= SCL_HALF) begin
                        cnt <= 24'd0;
                        if (MSB_FIRST)
                            shift <= {shift[KEY_NUM-2:0], sdo};
                        else
                            shift <= {sdo, shift[KEY_NUM-1:1]};

                        if (bit_i == KEY_NUM - 1)
                            state <= S_DONE;
                        else begin
                            bit_i <= bit_i + 5'd1;
                            state <= S_CLKH;
                        end
                    end
                    else cnt <= cnt + 24'd1;
                end

                // ---- 一轮读完：更新键状态 ----
                S_DONE: begin
                    key_state <= shift;
                    key_valid <= 1'b1;
                    cnt       <= 24'd0;
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
