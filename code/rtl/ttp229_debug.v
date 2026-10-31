// ============================================================================
//  模块名  : ttp229_debug.v
//  功能    : TTP229 位映射调试固件 —— 戳任意触摸键，LED 显示它的位号
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，27 MHz
//
//  ── 为什么要它 ────────────────────────────────────────────────────
//  TTP229 扫出 16 位，但"哪一位对应模块上哪个触摸点"只能实测。
//  本固件把"当前被按下的键的位号（0~15）"直接用 LED 二进制显示出来，
//  不需要声音、不需要合成器，接上两根线就能测。
//
//  ── 用法（实测步骤）──────────────────────────────────────────────
//      ① 接线：VCC→3V3、GND、SCL→75、SDO→76、RGB 悬空
//      ② 烧本固件
//      ③ 逐个戳触摸点，读出 LED[3:0] 的二进制值
//         例：led[3:0] 亮灭 = 亮-灭-灭-亮 → 二进制 1001 → 位号 9
//      ④ 记下"最低音对应的位号"和"最高音对应的位号"，
//         填入 synth_ttp229_top.v 的 TTP_BIT() 表
//
//  ── LED 定义（低电平点亮，亮 = 1）─────────────────────────────────
//      led[0..3] : 当前按键位号（二进制，0~15）
//      led[4]    : 有按键按下
//      led[5]    : 心跳（约 1.6 Hz，证明逻辑在跑）
//
//  ── 多键同时按 ────────────────────────────────────────────────────
//  显示位号最小的那个（优先编码从低位开始），便于逐个确认。
// ============================================================================
`timescale 1ns / 1ps

module ttp229_debug (
    input  wire       clk,
    output wire       ttp_scl,
    input  wire       ttp_sdo,
    output wire [5:0] led
);

    // ---- 上电复位 ----
    reg [15:0] por_cnt = 16'd0;
    reg        rst_n   = 1'b0;

    always @(posedge clk) begin
        if (&por_cnt) rst_n <= 1'b1;
        else          por_cnt <= por_cnt + 16'd1;
    end

    // ---- TTP229 读出 ----
    // ⚠ 2026-10-31：Qhebot 12 键钢琴板实测 TTP229 输出为低有效（0 = 按下），
    //    这里取反再送显示，否则未按时会显示"12 键全按"。
    wire [15:0] keys_raw;
    wire [15:0] keys = ~keys_raw;
    wire        keys_valid;

    ttp229_scan #(
        .KEY_NUM   (16),
        .SYNC_CNT  (5_400),
        .SCL_HALF  (27),
        .GAP_CNT   (270_000),      // 10 ms 扫描一次（调试时刷新更快）
        .MSB_FIRST (1)
    ) u_ttp (
        .clk       (clk),
        .rst_n     (rst_n),
        .sdo       (ttp_sdo),
        .scl       (ttp_scl),
        .key_state (keys_raw),
        .key_valid (keys_valid)
    );

    // ---- 找最低置位位（位号最小的按下键）----
    function [3:0] first_key;
        input [15:0] v;
        integer i;
        begin
            first_key = 4'd0;
            for (i = 15; i >= 0; i = i - 1)
                if (v[i]) first_key = i[3:0];
        end
    endfunction

    wire [3:0] cur_key = first_key(keys);
    wire       any_key = |keys;

    // ---- 心跳 ----
    reg [23:0] blink;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) blink <= 24'd0;
        else        blink <= blink + 24'd1;
    end

    // ---- LED：[5] 心跳  [4] 有键  [3:0] 位号 ----
    assign led = ~{ blink[23], any_key, cur_key };

endmodule
