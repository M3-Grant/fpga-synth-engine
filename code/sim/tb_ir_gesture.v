// ============================================================================
//  测试平台 : tb_ir_gesture.v
//  被测模块 : ir_gesture（红外挥手 → 音色切换）
//
//  策略     : 参数缩小到仿真可跑的量级（DEBOUNCE=540 / MIN=2160 / MAX=32400），
//             时间比例与上板一致（20ms / 80ms / 1200ms @27MHz）。
//             每个用例都是「驱动 ir_in → 跑固定周期 → 核对档位与脉冲计数」。
//
//  注       : 所有 tag 用 ASCII。中文 tag 经 $display 输出时会被控制台按
//             GBK 解码成乱码，且 256 位 tag 只能装 32 字节，中文会被截断。
//
//  运行     : iverilog -g2005 -o sim_ir.out rtl/debounce.v rtl/ir_gesture.v sim/tb_ir_gesture.v
// ============================================================================
`timescale 1ns / 1ps

module tb_ir_gesture;

    localparam CLK_PERIOD   = 37.037;
    localparam DEBOUNCE_CNT = 540;
    localparam MIN_SWIPE    = 2_160;
    localparam MAX_SWIPE    = 32_400;
    localparam INIT_SEL     = 3'd4;
    localparam N_COLORS     = 5;

    reg        clk, rst_n, ir_in;
    wire [2:0] wave_sel;
    wire       gesture_valid;
    wire       hand_level;
    wire       swipe_tooshort;
    wire       swipe_toolong;

    integer errors;
    integer gesture_cnt;
    integer short_cnt;
    integer long_cnt;

    ir_gesture #(
        .DEBOUNCE_CNT  (DEBOUNCE_CNT),
        .MIN_SWIPE_CNT (MIN_SWIPE),
        .MAX_SWIPE_CNT (MAX_SWIPE),
        .INIT_SEL      (INIT_SEL),
        .N_COLORS      (N_COLORS)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .ir_in         (ir_in),
        .wave_sel      (wave_sel),
        .gesture_valid (gesture_valid),
        .hand_level    (hand_level),
        .swipe_tooshort(swipe_tooshort),
        .swipe_toolong (swipe_toolong)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- 脉冲计数 ----
    always @(posedge clk) begin
        if (gesture_valid)  gesture_cnt = gesture_cnt + 1;
        if (swipe_tooshort) short_cnt   = short_cnt   + 1;
        if (swipe_toolong)  long_cnt    = long_cnt    + 1;
    end

    task run_clks;
        input [31:0] n;
        begin
            repeat (n) @(posedge clk);
        end
    endtask

    task chk;
        input [255:0] tag;
        input [0:0]   cond;
        begin
            if (cond) $display("  [PASS] %0s", tag);
            else begin
                $display("  [FAIL] %0s", tag);
                errors = errors + 1;
            end
        end
    endtask

    // One gesture: hand present for hold_clks, then leaves.
    // The measured hold_cnt is about hold_clks (both debounce delays cancel).
    task do_hold;
        input [31:0] hold_clks;
        begin
            @(negedge clk); ir_in = 1'b0;
            run_clks(hold_clks);
            @(negedge clk); ir_in = 1'b1;
            run_clks(DEBOUNCE_CNT * 4);
        end
    endtask

    initial begin
        $dumpfile("tb_ir_gesture.vcd");
        $dumpvars(0, tb_ir_gesture);

        errors      = 0;
        gesture_cnt = 0;
        short_cnt   = 0;
        long_cnt    = 0;

        clk   = 1'b0;
        rst_n = 1'b0;
        ir_in = 1'b1;

        #(CLK_PERIOD * 20);
        rst_n = 1'b1;
        run_clks(200);

        $display("==================================================");
        $display("  ir_gesture simulation");
        $display("  DEBOUNCE=%0d  MIN=%0d  MAX=%0d  INIT=%0d",
                 DEBOUNCE_CNT, MIN_SWIPE, MAX_SWIPE, INIT_SEL);
        $display("==================================================");

        // ---- check 1: reset default ----
        $display("[check1] reset -> default colour = piano(4), no pulses");
        chk("reset wave_sel == 4", wave_sel == 3'd4);
        chk("no gesture pulse", gesture_cnt == 0);
        chk("idle hand_level == 0", hand_level == 1'b0);

        // ---- check 2: glitch shorter than debounce ----
        $display("[check2] 100-clk glitch (< debounce 540) must be ignored");
        @(negedge clk); ir_in = 1'b0;
        run_clks(100);
        @(negedge clk); ir_in = 1'b1;
        run_clks(DEBOUNCE_CNT * 4);
        chk("glitch kept wave_sel = 4", wave_sel == 3'd4);
        chk("glitch produced no gesture", gesture_cnt == 0);
        chk("glitch not judged too-short", short_cnt == 0);

        // ---- check 3: valid swipe wraps 4 -> 0 ----
        $display("[check3] valid swipe (hold 10000) -> wrap 4 -> 0");
        do_hold(10_000);
        chk("wave_sel == 0", wave_sel == 3'd0);
        chk("gesture count == 1", gesture_cnt == 1);

        // ---- check 4/5: further swipes advance ----
        $display("[check4] swipe again -> 0 -> 1");
        do_hold(10_000);
        chk("wave_sel == 1", wave_sel == 3'd1);
        chk("gesture count == 2", gesture_cnt == 2);

        $display("[check5] swipe again -> 1 -> 2");
        do_hold(10_000);
        chk("wave_sel == 2", wave_sel == 3'd2);
        chk("gesture count == 3", gesture_cnt == 3);

        // ---- check 6: too short ----
        $display("[check6] hold 1000 (< MIN 2160) must be rejected");
        do_hold(1_000);
        chk("too-short kept wave_sel = 2", wave_sel == 3'd2);
        chk("too-short kept gesture = 3", gesture_cnt == 3);
        chk("too-short flag counted once", short_cnt == 1);

        // ---- check 7: too long ----
        $display("[check7] hold 40000 (> MAX 32400) must be rejected");
        do_hold(40_000);
        chk("too-long kept wave_sel = 2", wave_sel == 3'd2);
        chk("too-long kept gesture = 3", gesture_cnt == 3);
        chk("too-long flag counted once", long_cnt == 1);

        // ---- check 8: just above lower bound ----
        $display("[check8] hold 2400 (just above MIN) must be accepted");
        do_hold(2_400);
        chk("wave_sel == 3", wave_sel == 3'd3);
        chk("gesture count == 4", gesture_cnt == 4);

        // ---- summary ----
        $display("==================================================");
        if (errors == 0) $display("  RESULT: [PASS] all checks passed");
        else             $display("  RESULT: [FAIL] %0d check(s) failed", errors);
        $display("==================================================");
        $finish;
    end

endmodule
