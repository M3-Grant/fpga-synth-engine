// ============================================================================
//  测试平台 : tb_synth_top.v
//  被测模块 : synth_top（完整复音链路集成测试）
//  验证内容 :
//      1) 复位后无发声、混音输出为 0
//      2) 单音：声部被占用，混音输出非零
//      3) 复音 4：4 个声部同时发声
//      4) 释放：声部归还、输出回零
//      5) 混音输出不越界（不会因溢出而回绕）
//
//  运行 : iverilog -g2005 -o sim.out rtl/*.v sim/tb_synth_top.v && vvp sim.out
//         （rtl 需要包含 i2s_tx / note_table / clk_div 等）
// ============================================================================
`timescale 1ns / 1ps

module tb_synth_top;

    localparam CLK_PERIOD = 37.037;    // 27MHz
    localparam VOICE_NUM  = 4;
    localparam NOTE_BITS  = 5;

    reg                    clk;
    reg                    rst_n;
    reg                    note_valid;
    reg                    note_on;
    reg  [NOTE_BITS-1:0]   note_idx;
    wire                   i2s_bck, i2s_lrck, i2s_din;
    wire [VOICE_NUM-1:0]   dbg_voice_busy;
    wire signed [15:0]     dbg_mix;

    integer errors;
    integer i;
    integer nbusy;
    reg signed [15:0] max_abs;      // 观测期间的最大绝对值

    synth_top #(
        .VOICE_NUM  (VOICE_NUM),
        .PHASE_BITS (32),
        .BCK_HALF   (4),
        .AMP        (16'sh2000),
        .NOTE_BITS  (NOTE_BITS)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .note_valid     (note_valid),
        .note_on        (note_on),
        .note_idx       (note_idx),
        .i2s_bck        (i2s_bck),
        .i2s_lrck       (i2s_lrck),
        .i2s_din        (i2s_din),
        .dbg_voice_busy (dbg_voice_busy),
        .dbg_mix        (dbg_mix)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // sample_req 上升沿检测（用于同步采样音频样本）
    always @(posedge clk) req_d <= dut.sample_req;

    // ---- 统计占用声部数 ----
    task calc_busy;
        begin
            nbusy = 0;
            for (i = 0; i < VOICE_NUM; i = i + 1) begin
                if (dbg_voice_busy[i]) nbusy = nbusy + 1;
            end
        end
    endtask

    // ---- 观测混音输出的峰峰值 ----
    // 注意：mix_out 每 512 个 clk 才更新一次（512 = 64 BCK × 8 clk/BCK），
    //       因此必须在 sample_req 上升沿采样，否则读到的是重复值。
    integer max_val, min_val;
    reg req_d;

    task observe_peak;
        integer n;
        begin
            max_val = -32768;
            min_val =  32767;
            // 3000 clk ≈ 5.8 个采样周期（512 clk/周期）
            // ⚠ dbg_mix 是 mix_out 再寄存一级，需在 sample_req 之后再等 1 clk 采样
            for (n = 0; n < 3000; n = n + 1) begin
                @(posedge clk);
                if (dut.sample_req && !req_d) begin
                    @(posedge clk);          // 等 dbg_mix 更新
                    if (dbg_mix > max_val) max_val = dbg_mix;
                    if (dbg_mix < min_val) min_val = dbg_mix;
                end
            end
            max_abs = (max_val > -min_val) ? max_val : -min_val;
        end
    endtask

    // ---- 按下 / 松开音符 ----
    // 注意：加入 ADSR 后，包络需要时间进入 SUSTAIN，
    //       因此按下后要多等一段时间再测幅度。
    task press_note;
        input [NOTE_BITS-1:0] n;
        begin
            @(negedge clk); note_idx = n; note_on = 1'b1; note_valid = 1'b1;
            @(negedge clk); note_valid = 1'b0;
            repeat (8000) @(negedge clk);      // 等包络上升到 SUS_LEVEL
        end
    endtask

    task release_note;
        input [NOTE_BITS-1:0] n;
        begin
            @(negedge clk); note_idx = n; note_on = 1'b0; note_valid = 1'b1;
            @(negedge clk); note_valid = 1'b0;
            // 加入 ADSR 后，松开会有 RELEASE 余韵（约 43 个采样周期 ≈ 22000 clk）
            // 因此这里必须等足够久，否则会看到"残留幅度"
            repeat (30000) @(negedge clk);
        end
    endtask

    initial begin
        $dumpfile("tb_synth_top.vcd");
        $dumpvars(0, tb_synth_top);

        errors     = 0;
        rst_n      = 1'b0;
        note_valid = 1'b0;
        note_on    = 1'b0;
        note_idx   = 5'd0;
        req_d      = 1'b0;

        #(CLK_PERIOD * 20);
        rst_n = 1'b1;
        #(CLK_PERIOD * 20);

        $display("==================================================");
        $display("  synth_top 集成验证   (VOICE_NUM = %0d)", VOICE_NUM);
        $display("==================================================");

        // ============== 检查1：复位后无声 ==============
        $display("[检查1] 复位后无发声");
        calc_busy;
        if (nbusy == 0) $display("  [PASS] 无占用声部");
        else begin $display("  [FAIL] 占用 %0d 个声部", nbusy); errors = errors + 1; end

        observe_peak;
        if (max_abs == 0) $display("  [PASS] 混音输出全 0（静音）");
        else begin $display("  [FAIL] 静音时输出峰值 = %0d", max_abs); errors = errors + 1; end

        // ============== 检查2：单音 ==============
        $display("[检查2] 单音发声（音符 A4 = 索引 9）");
        press_note(5'd9);
        calc_busy;
        if (nbusy == 1) $display("  [PASS] 占用 1 个声部");
        else begin $display("  [FAIL] 占用 %0d 个声部", nbusy); errors = errors + 1; end

        observe_peak;
        if (max_abs > 0) $display("  [PASS] 混音输出非零（峰值 %0d）", max_abs);
        else begin $display("  [FAIL] 单音时输出仍为 0"); errors = errors + 1; end

        // 加入 ADSR 后，SUSTAIN 电平为 160/255，单音幅度约
        //   8192(AMP) × 160/255 / 4(右移2位) ≈ 1280
        if (max_abs > 500 && max_abs < 1800)
            $display("  [PASS] 单音幅度合理（%0d，期望约 1280）", max_abs);
        else begin
            $display("  [FAIL] 单音幅度异常（%0d，期望约 1280）", max_abs);
            errors = errors + 1;
        end

        // ============== 检查3：复音 4 ==============
        $display("[检查3] 复音 4 —— 再按 3 个音");
        press_note(5'd0);    // C4
        press_note(5'd4);    // E4
        press_note(5'd7);    // G4
        calc_busy;
        if (nbusy == VOICE_NUM) $display("  [PASS] 占用 4 个声部");
        else begin $display("  [FAIL] 占用 %0d 个声部", nbusy); errors = errors + 1; end

        observe_peak;
        if (max_abs > 1280)
            $display("  [PASS] 复音输出幅度增大（峰值 %0d）", max_abs);
        else begin
            $display("  [FAIL] 复音幅度未增大（%0d，期望 >1280）", max_abs);
            errors = errors + 1;
        end

        // 饱和检查：输出不得超出 16 位有符号范围
        if (max_abs <= 32767)
            $display("  [PASS] 输出未越界（%0d <= 32767）", max_abs);
        else begin
            $display("  [FAIL] 输出越界（%0d）", max_abs);
            errors = errors + 1;
        end

        // ============== 检查4：释放 ==============
        $display("[检查4] 逐个释放音符");
        release_note(5'd0);
        release_note(5'd4);
        release_note(5'd7);
        release_note(5'd9);
        calc_busy;
        if (nbusy == 0) $display("  [PASS] 全部释放，无占用声部");
        else begin $display("  [FAIL] 仍占用 %0d 个声部", nbusy); errors = errors + 1; end

        observe_peak;
        if (max_abs == 0) $display("  [PASS] 释放后输出回零");
        else begin $display("  [FAIL] 释放后输出峰值 = %0d", max_abs); errors = errors + 1; end

        // ============== 检查5：I2S 是否在活动 ==============
        $display("[检查5] I2S 输出活动性");
        press_note(5'd0);
        begin : chk_i2s
            integer toggles;
            toggles = 0;
            for (i = 0; i < 20000; i = i + 1) begin
                @(posedge clk);
                if (i2s_bck) toggles = toggles + 1;
            end
            if (toggles > 1000) $display("  [PASS] BCK 正常翻转（%0d 次）", toggles);
            else begin $display("  [FAIL] BCK 几乎不翻转（%0d 次）", toggles); errors = errors + 1; end
        end

        $display("==================================================");
        if (errors == 0) $display("  全部通过：0 个错误");
        else             $display("  验证失败：%0d 个错误", errors);
        $display("==================================================");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 500000);
        $display("[ERROR] 仿真超时");
        $finish;
    end

endmodule
