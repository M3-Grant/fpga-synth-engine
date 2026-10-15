// ============================================================================
//  模块名  : key_scan.v
//  功能    : 12 路按键扫描 —— 消抖 + 锁存 + 逐拍上报音符事件
//  板卡    : Siliece Tang Nano 20K (GW2AR-18)，主时钟 27 MHz
//
//  ── 为什么需要这个模块 ────────────────────────────────────────────
//  之前 synth_board_top 用「2 键状态机」切换音阶，只能演示、不能演奏。
//  本模块把 12 个物理按键变成 12 个独立音符事件，每个键对应一个音。
//
//  ── 设计演进（四次改错才定型的教训，值得记下来）──────────────────
//  ① 两个 always 块分别驱动 note_valid → 多驱动，综合会出错。
//     必须单一 always、单一出口。
//  ② "流式扫描 key_press" 行不通：key_press 是 debounce 输出的
//     **单周期脉冲**，而扫描要 12 拍才轮到对应位置，事件早消失了。
//     实测 t=12 出现 press 脉冲，t=15 才扫到该位（已是 0）→ 事件全丢。
//  ③ 锁存变量的**置位与清除也必须放在同一个 always 块**里，
//     否则又是多驱动（第二次踩同一个坑）。
//  ④ 最终方案：锁存边沿 + 优先编码 + 逐拍上报清除，全在一个 always 内。
//
//  作者    : 第三代 beta3
// ============================================================================
`timescale 1ns / 1ps
module key_scan #(
    parameter KEY_NUM    = 12,        // 按键数
    parameter CNT_MAX    = 270_000,   // 消抖时间（27MHz 下约 10ms）
    parameter ACTIVE_LOW = 0,         // 0 = 按下为高（TTP223 默认）
    parameter NOTE_BITS  = 5
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire [KEY_NUM-1:0]      key_in,      // 原始按键输入
    output wire [KEY_NUM-1:0]      key_state,   // 消抖后电平（1=按下），供 LED
    output reg                     note_valid,  // 单周期脉冲
    output reg                     note_on,     // 1=按下 0=松开
    output reg  [NOTE_BITS-1:0]    note_idx     // 音符索引
);

    // ==================================================================
    // 1. 按键 → 音符映射（12 键 = 一个完整八度含半音）
    //    note_table 索引：0=C4，每 +1 一个半音
    // ==================================================================
    function [NOTE_BITS-1:0] key2note;
        input [3:0] k;
        begin
            case (k)
                4'd0 : key2note = 5'd0;    // C4
                4'd1 : key2note = 5'd1;    // C#4
                4'd2 : key2note = 5'd2;    // D4
                4'd3 : key2note = 5'd3;    // D#4
                4'd4 : key2note = 5'd4;    // E4
                4'd5 : key2note = 5'd5;    // F4
                4'd6 : key2note = 5'd6;    // F#4
                4'd7 : key2note = 5'd7;    // G4
                4'd8 : key2note = 5'd8;    // G#4
                4'd9 : key2note = 5'd9;    // A4
                4'd10: key2note = 5'd10;   // A#4
                4'd11: key2note = 5'd11;   // B4
                default: key2note = 5'd0;
            endcase
        end
    endfunction

    // ==================================================================
    // 2. KEY_NUM 路并行消抖
    // ==================================================================
    wire [KEY_NUM-1:0] key_press;    // 按下瞬间的单周期脉冲

    genvar i;
    generate
        for (i = 0; i < KEY_NUM; i = i + 1) begin : gen_db
            debounce #(
                .CNT_MAX    (CNT_MAX),
                .ACTIVE_LOW (ACTIVE_LOW)
            ) u_db (
                .clk       (clk),
                .rst_n     (rst_n),
                .key_in    (key_in[i]),
                .key_state (key_state[i]),
                .key_press (key_press[i])
            );
        end
    endgenerate

    // ==================================================================
    // 3. 释放沿检测
    // ==================================================================
    reg [KEY_NUM-1:0] key_state_d;

    wire [KEY_NUM-1:0] key_release = key_state_d & ~key_state;

    // ==================================================================
    // 4. 锁存 + 上报（单一 always 完成：锁存新事件、上报、清除）
    //
    //    优先级：按下事件 > 松开事件
    //    每拍最多上报一个音符，12 拍扫完一轮（0.44us）
    // ==================================================================
    reg [KEY_NUM-1:0] press_lat;
    reg [KEY_NUM-1:0] rel_lat;

    // 优先编码：取最低置位位号
    function [3:0] find_lowest;
        input [KEY_NUM-1:0] v;
        integer j;
        begin
            find_lowest = 4'd0;
            for (j = KEY_NUM - 1; j >= 0; j = j - 1) begin
                if (v[j]) find_lowest = j[3:0];
            end
        end
    endfunction

    // ---- 先与新到的边沿事件合并，再判断/上报 ----
    // 判断和上报都必须基于**合并后**的值，否则「这一拍刚来的事件」
    // 要等到下一拍才被看见，白白多花一拍。
    wire [KEY_NUM-1:0] press_merged = press_lat | key_press;
    wire [KEY_NUM-1:0] rel_merged   = rel_lat   | key_release;

    wire              has_press = |press_merged;
    wire              has_rel   = |rel_merged;
    wire [3:0]        p_idx     = find_lowest(press_merged);
    wire [3:0]        r_idx     = find_lowest(rel_merged);

    // ---- 下一拍的锁存值：把本拍上报掉的那一位清掉 ----
    reg [KEY_NUM-1:0] press_next;
    reg [KEY_NUM-1:0] rel_next;

    always @(*) begin
        press_next = press_merged;
        if (has_press) press_next[p_idx] = 1'b0;

        rel_next = rel_merged;
        if (has_rel && !has_press) rel_next[r_idx] = 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_state_d <= {KEY_NUM{1'b0}};
            press_lat   <= {KEY_NUM{1'b0}};
            rel_lat     <= {KEY_NUM{1'b0}};
            note_valid  <= 1'b0;
            note_on     <= 1'b0;
            note_idx    <= {NOTE_BITS{1'b0}};
        end
        else begin
            key_state_d <= key_state;
            note_valid  <= 1'b0;                 // 默认无事件

            // ---- 锁存更新：合并新事件 + 清掉本拍已上报的位 ----
            // 🔴 原写法是个真 bug（和弦缺音）：
            //      if (key_press)  press_lat <= key_press;        // 覆盖赋值
            //      else if (has_press) press_lat[p_idx] <= 0;
            //   ① 覆盖 → 和弦上报途中若有新键按下，未处理的位被冲掉，
            //      实测 C-E-G 三音和弦里 G4 的 note-on 次数变成 0（音不响）。
            //   ② 若只改成 |= 累积而不改清除，又变成同一位被上报两次
            //      （E4 收到 2 次 note-on），会重复触发。
            //   最终方案：合并 → 上报 → 清除 在同一拍一起完成。
            press_lat <= press_next;
            rel_lat   <= rel_next;

            // ---- 上报（按下优先），每拍一个事件 ----
            if (has_press) begin
                note_valid <= 1'b1;
                note_on    <= 1'b1;
                note_idx   <= key2note(p_idx);
            end
            else if (has_rel) begin
                note_valid <= 1'b1;
                note_on    <= 1'b0;
                note_idx   <= key2note(r_idx);
            end
        end
    end

endmodule
