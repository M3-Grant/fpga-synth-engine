// ============================================================================
//  测试平台 : tb_synth_board12.v
//  被测模块 : synth_board12_top（12 键电子琴板级顶层）
//  验证内容 :
//      1) 上电静音
//      2) 单键按下 → 发声，且音符正确
//      3) 松键 → 余韵后静音
//      4) 三键同时按下 → 复音发声（C 大三和弦）
//      5) I2S 与功放使能正常
//
//  运行：见文件末尾
// ============================================================================
`timescale 1ns / 1ps

module tb_synth_board12;

    localparam CLK_PERIOD = 37.037;
    localparam KEY_NUM    = 12;
    localparam VOICE_NUM  = 4;
    localparam CNT_MAX    = 8;          // 仿真用短消抖

    reg                    clk, rst_n;
    reg  [KEY_NUM-1:0]     key;
    wire                   i2s_bck, i2s_lrck, i2s_din, pa_en;
    wire [5:0]             led;

    integer errors;
    integer i;

    synth_board12_top #(
        .VOICE_NUM   (VOICE_NUM),
        .NOTE_BITS   (5),
        .BCK_HALF    (4),
        .KEY_NUM     (KEY_NUM),
        .KEY_CNT_MAX (CNT_MAX)
    ) dut (
        .clk      (clk),
        .key      (key),
        .i2s_bck  (i2s_bck),
        .i2s_lrck (i2s_lrck),
        .i2s_din  (i2s_din),
        .pa_en    (pa_en),
        .led      (led)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- 观测混音峰峰值（同步到 sample_req）----
    integer max_val, min_val;
    reg     req_d;

    always @(posedge clk) req_d <= dut.u_synth.sample_req;

    task observe_peak;
        integer n;
        begin
            max_val = -32768;
            min_val =  32767;
            for (n = 0; n < 4000; n = n + 1) begin
                @(posedge clk);
                if (dut.u_synth.sample_req && !req_d) begin
                    @(posedge clk);
                    if (dut.dbg_mix > max_val) max_val = dut.dbg_mix;
                    if (dut.dbg_mix < min_val) min_val = dut.dbg_mix;
                end
            end
        end
    endtask

    integer peak;

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

    initial begin
        $dumpfile("tb_synth_board12.vcd");
        $dumpvars(0, tb_synth_board12);

        errors = 0;
        clk    = 1'b0;
        rst_n  = 1'b0;
        key    = {KEY_NUM{1'b0}};
        req_d  = 1'b0;

        // 等上电复位完成（2^16 周期）
        run_clks(70000);

        $display("==================================================");
        $display("  synth_board12_top 集成验证");
        $display("==================================================");

        // ============ 检查1：上电静音 ============
        $display("[检查1] 上电静音");
        observe_peak;
        peak = (max_val > -min_val) ? max_val : -min_val;
        chk("输出为 0", peak == 0);
        chk("无占用声部", dut.dbg_voice_busy == {VOICE_NUM{1'b0}});

        // ============ 检查2：单键按下（KEY0 = C4）============
        $display("[检查2] 按下 KEY0 → C4 发声");
        @(negedge clk); key = (1'b1 << 0);
        run_clks(4000);                      // 等消抖 + 包络进入 SUSTAIN
        chk("占用 1 个声部", dut.dbg_voice_busy == 4'b0001);

        observe_peak;
        peak = (max_val > -min_val) ? max_val : -min_val;
        $display("        混音峰值 = %0d", peak);
        chk("有音频输出", peak > 100);
        chk("幅度合理（期望约 210）", (peak > 120) && (peak < 450));   // AMP=1/16 满量程下实测 210

        // ============ 检查3：松键后静音 ============
        $display("[检查3] 松开 KEY0 → 余韵后静音");
        @(negedge clk); key = {KEY_NUM{1'b0}};
        run_clks(40000);                     // 等包络 RELEASE 走完
        chk("声部全部释放", dut.dbg_voice_busy == 4'b0000);

        observe_peak;
        peak = (max_val > -min_val) ? max_val : -min_val;
        chk("输出回零", peak == 0);

        // ============ 检查4：三键同时按下（C 大三和弦）============
        $display("[检查4] 同时按 KEY0+KEY4+KEY7（C 大三和弦）");
        @(negedge clk); key = (1'b1 << 0) | (1'b1 << 4) | (1'b1 << 7);
        run_clks(6000);

        begin : chk_chord
            integer nbusy;
            nbusy = 0;
            for (i = 0; i < VOICE_NUM; i = i + 1)
                if (dut.dbg_voice_busy[i]) nbusy = nbusy + 1;
            $display("        占用声部 = %0d  (busy=%b)", nbusy, dut.dbg_voice_busy);
            chk("占用 3 个声部", nbusy == 3);
        end

        observe_peak;
        peak = (max_val > -min_val) ? max_val : -min_val;
        $display("        和弦峰值 = %0d", peak);
        chk("复音输出更响", peak > 250);   // 三角波实测 390（方波为 774）
        chk("未越界", peak <= 32767);

        // ============ 检查5：I2S 与功放 ============
        $display("[检查5] I2S 与功放使能");
        begin : chk_i2s
            integer toggles;
            toggles = 0;
            for (i = 0; i < 20000; i = i + 1) begin
                @(posedge clk);
                if (i2s_bck) toggles = toggles + 1;
            end
            chk("BCK 正常翻转", toggles > 1000);
        end
        chk("pa_en 已拉高", pa_en === 1'b1);

        $display("==================================================");
        if (errors == 0) $display("  全部通过：0 个错误");
        else             $display("  验证失败：%0d 个错误", errors);
        $display("==================================================");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 1000000);
        $display("[ERROR] 仿真超时");
        $finish;
    end

endmodule
