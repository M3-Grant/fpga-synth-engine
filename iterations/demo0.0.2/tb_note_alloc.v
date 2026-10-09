// ============================================================================
//  测试平台 : tb_note_alloc.v
//  被测模块 : note_alloc
//  验证内容 : 复位 / 单音分配 / 松开释放 / 复音4 / 抢占 / 重复按键
//
//  写法说明：全部内联，不使用 task/function。
//            iverilog 对带 ANSI 风格端口的 task 在某些组合下会报
//            "port already declared"，实测内联写法最稳。
//
//  运行 : iverilog -g2005 -o sim.out rtl/note_alloc.v sim/tb_note_alloc.v && vvp sim.out
// ============================================================================
`timescale 1ns / 1ps

module tb_note_alloc;

    localparam CLK_PERIOD = 37.037;
    localparam VOICE_NUM  = 4;
    localparam NOTE_BITS  = 5;

    reg                   clk;
    reg                   rst_n;
    reg                   note_valid;
    reg                   note_on;
    reg  [NOTE_BITS-1:0]  note_idx;
    wire [VOICE_NUM-1:0]  voice_busy;
    wire [VOICE_NUM*NOTE_BITS-1:0] voice_note;
    wire [VOICE_NUM-1:0]  voice_trig;

    integer errors;
    integer i;
    integer nbusy;
    reg [4:0] got0, got1, got2, got3;

    note_alloc #(
        .VOICE_NUM (VOICE_NUM),
        .NOTE_BITS (NOTE_BITS)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .note_valid (note_valid),
        .note_on    (note_on),
        .note_idx   (note_idx),
        .voice_busy (voice_busy),
        .voice_note (voice_note),
        .voice_trig (voice_trig)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // 取声部音符的便捷线
    wire [4:0] vn0 = voice_note[0*NOTE_BITS +: NOTE_BITS];
    wire [4:0] vn1 = voice_note[1*NOTE_BITS +: NOTE_BITS];
    wire [4:0] vn2 = voice_note[2*NOTE_BITS +: NOTE_BITS];
    wire [4:0] vn3 = voice_note[3*NOTE_BITS +: NOTE_BITS];

    initial begin
        $dumpfile("tb_note_alloc.vcd");
        $dumpvars(0, tb_note_alloc);

        errors     = 0;
        rst_n      = 1'b0;
        note_valid = 1'b0;
        note_on    = 1'b0;
        note_idx   = 5'd0;

        #(CLK_PERIOD * 20);
        rst_n = 1'b1;
        #(CLK_PERIOD * 20);

        $display("==================================================");
        $display("  note_alloc 仿真验证   (VOICE_NUM = %0d)", VOICE_NUM);
        $display("==================================================");

        // ================= 检查1：复位后全空闲 =================
        $display("[检查1] 复位后所有声部空闲");
        if (voice_busy === 4'b0000) $display("  [PASS] voice_busy 全 0");
        else begin $display("  [FAIL] voice_busy = %b", voice_busy); errors = errors + 1; end

        // ================= 检查2：按下音符0 → 占声部0 =================
        $display("[检查2] 单音分配");
        @(negedge clk); note_idx = 5'd0; note_on = 1'b1; note_valid = 1'b1;
        @(negedge clk); note_valid = 1'b0;
        @(negedge clk);

        if (voice_busy[0] && vn0 == 5'd0) $display("  [PASS] 音符0 分配到声部0");
        else begin $display("  [FAIL] 声部0 busy=%b note=%0d", voice_busy[0], vn0); errors = errors + 1; end

        // ================= 检查3：松开音符0 → 释放 =================
        $display("[检查3] 松开释放声部");
        @(negedge clk); note_idx = 5'd0; note_on = 1'b0; note_valid = 1'b1;
        @(negedge clk); note_valid = 1'b0;
        @(negedge clk);

        nbusy = 0;
        for (i = 0; i < VOICE_NUM; i = i + 1) if (voice_busy[i]) nbusy = nbusy + 1;
        if (nbusy == 0) $display("  [PASS] 松开后占用 0 个声部");
        else begin $display("  [FAIL] 松开后仍占用 %0d 个声部", nbusy); errors = errors + 1; end

        // ================= 检查4：复音 —— 同时按 4 个音 =================
        $display("[检查4] 复音分配 —— 同时按 4 个音");
        @(negedge clk); note_idx = 5'd0; note_on = 1'b1; note_valid = 1'b1;
        @(negedge clk); note_valid = 1'b0; @(negedge clk);
        @(negedge clk); note_idx = 5'd2; note_on = 1'b1; note_valid = 1'b1;
        @(negedge clk); note_valid = 1'b0; @(negedge clk);
        @(negedge clk); note_idx = 5'd4; note_on = 1'b1; note_valid = 1'b1;
        @(negedge clk); note_valid = 1'b0; @(negedge clk);
        @(negedge clk); note_idx = 5'd6; note_on = 1'b1; note_valid = 1'b1;
        @(negedge clk); note_valid = 1'b0; @(negedge clk);

        nbusy = 0;
        for (i = 0; i < VOICE_NUM; i = i + 1) if (voice_busy[i]) nbusy = nbusy + 1;
        if (nbusy == VOICE_NUM) $display("  [PASS] 占用 4 个声部 (0/2/4/6)");
        else begin $display("  [FAIL] 占用 %0d 个声部，期望 %0d", nbusy, VOICE_NUM); errors = errors + 1; end

        if (vn0 == 5'd0 && vn1 == 5'd2 && vn2 == 5'd4 && vn3 == 5'd6)
            $display("  [PASS] 四声部分别为 0/2/4/6，无冲突");
        else begin
            $display("  [FAIL] 声部音符 = %0d/%0d/%0d/%0d，期望 0/2/4/6", vn0, vn1, vn2, vn3);
            errors = errors + 1;
        end

        // ================= 检查5：第 5 个音 → 抢占 =================
        $display("[检查5] 声部占满时的抢占");
        @(negedge clk); note_idx = 5'd8; note_on = 1'b1; note_valid = 1'b1;
        @(negedge clk); note_valid = 1'b0; @(negedge clk);

        nbusy = 0;
        for (i = 0; i < VOICE_NUM; i = i + 1) if (voice_busy[i]) nbusy = nbusy + 1;
        if (nbusy == VOICE_NUM) $display("  [PASS] 抢占后仍占 4 个声部");
        else begin $display("  [FAIL] 抢占后占用 %0d 个声部", nbusy); errors = errors + 1; end

        if (vn0 == 5'd8 || vn1 == 5'd8 || vn2 == 5'd8 || vn3 == 5'd8)
            $display("  [PASS] 音符8 已被分配到某声部");
        else begin $display("  [FAIL] 音符8 未出现"); errors = errors + 1; end

        // ================= 检查6：重复按同一音符 =================
        $display("[检查6] 重复按同一音符（不应占新声部）");
        // 先松开 8 和 6
        @(negedge clk); note_idx = 5'd8; note_on = 1'b0; note_valid = 1'b1;
        @(negedge clk); note_valid = 1'b0; @(negedge clk);
        @(negedge clk); note_idx = 5'd6; note_on = 1'b0; note_valid = 1'b1;
        @(negedge clk); note_valid = 1'b0; @(negedge clk);
        // 此时应剩 0 和 2（2 个声部）
        nbusy = 0;
        for (i = 0; i < VOICE_NUM; i = i + 1) if (voice_busy[i]) nbusy = nbusy + 1;
        if (nbusy == 2) $display("  [PASS] 松开后剩 2 个声部");
        else begin $display("  [FAIL] 剩 %0d 个声部，期望 2", nbusy); errors = errors + 1; end
        // 重复按「仍在发声」的音符2（当前在声部1）——应复用而非新占声部
        @(negedge clk); note_idx = 5'd2; note_on = 1'b1; note_valid = 1'b1;
        @(negedge clk); note_valid = 1'b0; @(negedge clk);
        nbusy = 0;
        for (i = 0; i < VOICE_NUM; i = i + 1) if (voice_busy[i]) nbusy = nbusy + 1;
        if (nbusy == 2) $display("  [PASS] 重复按音符2 未增加占用（复用原声部）");
        else begin $display("  [FAIL] 重复按键后占用 %0d 个声部，期望 2", nbusy); errors = errors + 1; end

        // ================= 汇总 =================
        $display("==================================================");
        if (errors == 0) $display("  全部通过：0 个错误");
        else             $display("  验证失败：%0d 个错误", errors);
        $display("==================================================");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 50000);
        $display("[ERROR] 仿真超时");
        $finish;
    end

endmodule
