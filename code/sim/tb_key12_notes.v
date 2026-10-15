// ============================================================================
//  测试平台 : tb_key12_notes.v
//  被测模块 : key_scan（12 键 → 12 个半音映射）
//
//  验证内容 :
//      1) 12 个键逐个按下，各自上报正确的 note_idx（0=C4 ... 11=B4）
//      2) 和弦：3 键同时按下，3 个 note-on 事件一个都不能丢
//      3) 🐛 回归：和弦上报**中途**再插入新键（这是我修过的 bug 场景）
//         修复前 press_lat 是覆盖赋值，新键会把未处理的位冲掉；
//         修复后改成按位或，4 个事件都必须收到
//
//  运行 : iverilog -g2005 -o sim_key12.out rtl/debounce.v rtl/key_scan.v \
//                                          sim/tb_key12_notes.v
//         vvp sim_key12.out
// ============================================================================
`timescale 1ns / 1ps

module tb_key12_notes;

    localparam CLK_PERIOD = 37.037;    // 27 MHz
    localparam KEY_NUM    = 12;
    localparam NOTE_BITS  = 5;
    localparam CNT_MAX    = 8;         // 仿真用小值（实物是 270_000 ≈ 10ms）

    reg                    clk = 1'b0;
    reg                    rst_n = 1'b0;
    reg  [KEY_NUM-1:0]     key_in = {KEY_NUM{1'b0}};

    wire [KEY_NUM-1:0]     key_state;
    wire                   note_valid;
    wire                   note_on;
    wire [NOTE_BITS-1:0]   note_idx;

    key_scan #(
        .KEY_NUM    (KEY_NUM),
        .CNT_MAX    (CNT_MAX),
        .ACTIVE_LOW (0),           // TTP223：按下为高
        .NOTE_BITS  (NOTE_BITS)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .key_in    (key_in),
        .key_state (key_state),
        .note_valid(note_valid),
        .note_on   (note_on),
        .note_idx  (note_idx)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // ------------------------------------------------------------------
    // 事件收集器：把每次 note_valid 记进数组
    // ------------------------------------------------------------------
    integer errors;
    integer evt_cnt;
    integer k;
    integer j;          // task 内部专用（不能复用 k，否则外层 for 会被破坏）
    integer noff;

    reg [NOTE_BITS-1:0] evt_note [0:63];
    reg                 evt_on   [0:63];

    always @(posedge clk) begin
        if (rst_n && note_valid) begin
            if (evt_cnt < 64) begin
                evt_note[evt_cnt] = note_idx;
                evt_on[evt_cnt]   = note_on;
                evt_cnt           = evt_cnt + 1;
            end
        end
    end

    // ------------------------------------------------------------------
    // 辅助：音名字符串
    // ------------------------------------------------------------------
    function [47:0] note_name;
        input [NOTE_BITS-1:0] n;
        begin
            case (n)
                5'd0 : note_name = "C4  ";
                5'd1 : note_name = "C#4 ";
                5'd2 : note_name = "D4  ";
                5'd3 : note_name = "D#4 ";
                5'd4 : note_name = "E4  ";
                5'd5 : note_name = "F4  ";
                5'd6 : note_name = "F#4 ";
                5'd7 : note_name = "G4  ";
                5'd8 : note_name = "G#4 ";
                5'd9 : note_name = "A4  ";
                5'd10: note_name = "A#4 ";
                5'd11: note_name = "B4  ";
                default: note_name = "??  ";
            endcase
        end
    endfunction

    // 按下 / 松开
    task press;
        input [KEY_NUM-1:0] m;
        begin
            key_in = key_in | m;
            repeat (CNT_MAX + 6) @(posedge clk);
        end
    endtask

    task release_k;
        input [KEY_NUM-1:0] m;
        begin
            key_in = key_in & ~m;
            repeat (CNT_MAX + 6) @(posedge clk);
        end
    endtask

    // 等待事件上报完毕
    task settle;
        begin
            repeat (KEY_NUM + 8) @(posedge clk);
        end
    endtask

    // 在收到的事件里查找某个音符的 note-on
    integer found;
    task expect_note_on;
        input [NOTE_BITS-1:0] n;
        begin
            found = 0;
            for (j = 0; j < evt_cnt; j = j + 1) begin
                if (evt_on[j] && evt_note[j] == n) found = found + 1;
            end
            if (found == 1)
                $display("  [PASS] 音符 %0d (%0s) 收到 1 次 note-on", n, note_name(n));
            else begin
                $display("  [FAIL] 音符 %0d (%0s) note-on 次数 = %0d（期望 1）",
                         n, note_name(n), found);
                errors = errors + 1;
            end
        end
    endtask

    // ==================================================================
    initial begin
        $dumpfile("tb_key12_notes.vcd");
        $dumpvars(0, tb_key12_notes);

        errors  = 0;
        evt_cnt = 0;
        for (k = 0; k < 64; k = k + 1) begin
            evt_note[k] = 5'd0;
            evt_on[k]   = 1'b0;
        end

        #(CLK_PERIOD * 10);
        rst_n = 1'b1;
        #(CLK_PERIOD * 10);
        evt_cnt = 0;

        $display("==================================================");
        $display("  12 键音符映射验证   (key_scan, CNT_MAX=%0d)", CNT_MAX);
        $display("==================================================");

        // ============ 检查 1：12 键逐个按下 ============
        $display("[检查1] 12 个键各自发出对应音符");
        for (k = 0; k < KEY_NUM; k = k + 1) begin
            evt_cnt = 0;
            press(1 << k);
            settle;
            expect_note_on(k[NOTE_BITS-1:0]);
            release_k(1 << k);
            settle;
            evt_cnt = 0;
        end

        // ============ 检查 2：三键和弦 ============
        $display("[检查2] 和弦：KEY0 + KEY4 + KEY7 同时按下（C 大三和弦）");
        evt_cnt = 0;
        press((1 << 0) | (1 << 4) | (1 << 7));
        settle;
        expect_note_on(5'd0);
        expect_note_on(5'd4);
        expect_note_on(5'd7);
        release_k((1 << 0) | (1 << 4) | (1 << 7));
        settle;
        evt_cnt = 0;

        // ============ 检查 3：🐛 和弦上报中途插入新键 ============
        // 这是原先 `press_lat <= key_press`（覆盖）会踩坑的场景：
        // 先按 3 个键（需要 3 拍逐个上报），只等 1 拍就再按第 4 个键。
        $display("[检查3] 回归：和弦上报中途再插入 KEY2（原 bug 场景）");
        // 时序设计（CNT_MAX=8，按下后约 10 拍才出 key_press 脉冲）：
        //   t=0  按下 key0/4/7        → t≈10 出现 press 脉冲，press_lat=0b10010001
        //   t=11 上报 idx0            → press_lat 变 0b10010000（还剩 2 个待处理）
        //   t=2  按下 key2            → t≈12 出现 press 脉冲  ★ 正好落在上报期间
        //   修复前：press_lat <= key_press  → 0b100 覆盖，bit4/bit7 丢失
        //   修复后：press_lat |= key_press  → 0b10010100，4 个都在
        evt_cnt = 0;
        key_in = (1 << 0) | (1 << 4) | (1 << 7);
        repeat (2) @(posedge clk);            // 只错开 2 拍
        key_in = key_in | (1 << 2);           // 插入新键
        repeat (CNT_MAX + 10) @(posedge clk);
        settle;

        expect_note_on(5'd0);
        expect_note_on(5'd4);
        expect_note_on(5'd7);
        expect_note_on(5'd2);                 // ← 修复前这个会丢

        release_k(12'hFFF);
        settle;

        // ============ 检查 4：松开事件 ============
        $display("[检查4] 松开后收到 note-off");
        evt_cnt = 0;
        press(1 << 5);
        settle;
        release_k(1 << 5);
        settle;
        begin
            noff = 0;
            for (k = 0; k < evt_cnt; k = k + 1) begin
                if (!evt_on[k] && evt_note[k] == 5'd5) noff = noff + 1;
            end
            if (noff == 1) $display("  [PASS] 音符 5 收到 1 次 note-off");
            else begin
                $display("  [FAIL] 音符 5 note-off 次数 = %0d（期望 1）", noff);
                errors = errors + 1;
            end
        end

        $display("==================================================");
        if (errors == 0) $display("  全部通过：0 个错误");
        else             $display("  验证失败：%0d 个错误", errors);
        $display("==================================================");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 400000);
        $display("[ERROR] 仿真超时");
        $finish;
    end

endmodule
