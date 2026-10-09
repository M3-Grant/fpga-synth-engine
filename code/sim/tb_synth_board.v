// ============================================================================
//  测试平台 : tb_synth_board.v
//  被测模块 : synth_board_top（板级顶层）
//  验证内容 :
//      1) 复位后无声、LED 心跳在跑
//      2) 按 KEY1 → 发声（音符 C4）
//      3) 按 KEY2 → 音阶步进（C→D→E...）
//      4) 再按 KEY1 → 停声
//      5) I2S 信号正常翻转
//
//  运行 : iverilog -g2005 -o sim.out rtl/*.v sim/tb_synth_board.v && vvp sim.out
// ============================================================================
`timescale 1ns / 1ps

module tb_synth_board;

    localparam CLK_PERIOD = 37.037;

    reg         clk, key1, key2;
    wire        i2s_bck, i2s_lrck, i2s_din, pa_en;
    wire [5:0]  led;

    integer errors;

    synth_board_top #(
        .VOICE_NUM (4),
        .NOTE_BITS (5),
        .BCK_HALF  (4)
    ) dut (
        .clk      (clk),
        .key1     (key1),
        .key2     (key2),
        .i2s_bck  (i2s_bck),
        .i2s_lrck (i2s_lrck),
        .i2s_din  (i2s_din),
        .pa_en    (pa_en),
        .led      (led)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // 按键动作：按下 → 保持 → 松开（消抖需要 >10ms ≈ 270000 clk）
    task press_key1;
        begin
            @(negedge clk); key1 = 1'b1;
            repeat (300000) @(negedge clk);
            @(negedge clk); key1 = 1'b0;
            repeat (300000) @(negedge clk);
        end
    endtask

    task press_key2;
        begin
            @(negedge clk); key2 = 1'b1;
            repeat (300000) @(negedge clk);
            @(negedge clk); key2 = 1'b0;
            repeat (300000) @(negedge clk);
        end
    endtask

    // 观测混音输出的峰峰值（同步到 sample_req）
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

    initial begin
        $dumpfile("tb_synth_board.vcd");
        $dumpvars(0, tb_synth_board);

        errors = 0;
        clk    = 1'b0;
        key1   = 1'b0;
        key2   = 1'b0;
        req_d  = 1'b0;

        // 上电复位是模块内部的（约 2.4ms），等它完成
        #(CLK_PERIOD * 100000);

        $display("==================================================");
        $display("  synth_board_top 板级验证");
        $display("==================================================");

        // ===== 检查1：上电静音 =====
        $display("[检查1] 上电后静音");
        observe_peak;
        peak = (max_val > -min_val) ? max_val : -min_val;
        if (peak == 0) $display("  [PASS] 输出为 0（静音）");
        else begin $display("  [FAIL] 上电即有输出 %0d", peak); errors = errors + 1; end

        if (dut.u_synth.dbg_voice_busy == 4'b0000)
            $display("  [PASS] 无占用声部");
        else begin $display("  [FAIL] 有 %b 个声部被占用", dut.u_synth.dbg_voice_busy); errors = errors + 1; end

        // ===== 检查2：按 KEY1 发声 =====
        $display("[检查2] 按 KEY1 → 发声（C4）");
        press_key1;
        $display("        当前音阶位置 scale_pos = %0d，音符索引 = %0d",
                 dut.scale_pos, dut.scale_note);
        if (dut.note_active) $display("  [PASS] note_active = 1");
        else begin $display("  [FAIL] note_active = 0"); errors = errors + 1; end

        observe_peak;
        peak = (max_val > -min_val) ? max_val : -min_val;
        if (peak > 100) $display("  [PASS] 有音频输出（峰值 %0d）", peak);
        else begin $display("  [FAIL] 无音频输出（峰值 %0d）", peak); errors = errors + 1; end

        // ===== 检查3：按 KEY1 再停声 =====
        $display("[检查3] 再按 KEY1 → 停声");
        press_key1;
        if (!dut.note_active) $display("  [PASS] note_active = 0");
        else begin $display("  [FAIL] note_active 仍为 1"); errors = errors + 1; end
        // 等包络余韵走完
        repeat (40000) @(negedge clk);
        observe_peak;
        peak = (max_val > -min_val) ? max_val : -min_val;
        if (peak == 0) $display("  [PASS] 余韵结束后输出归零");
        else begin $display("  [FAIL] 仍有残留输出 %0d", peak); errors = errors + 1; end

        // ===== 检查4：按 KEY2 音阶步进 =====
        $display("[检查4] 按 KEY2 → 音阶步进");
        begin : chk_scale
            reg [2:0] pos0;
            pos0 = dut.scale_pos;
            press_key2;
            $display("        scale_pos: %0d → %0d", pos0, dut.scale_pos);
            if (dut.scale_pos == pos0 + 3'd1)
                $display("  [PASS] 音阶前进一格");
            else begin
                $display("  [FAIL] 音阶未前进（%0d → %0d）", pos0, dut.scale_pos);
                errors = errors + 1;
            end
        end

        // 再按几次，验证回绕
        press_key2; press_key2; press_key2; press_key2; press_key2;
        press_key2; press_key2;
        $display("        连续步进后 scale_pos = %0d", dut.scale_pos);
        if (dut.scale_pos == 3'd0)
            $display("  [PASS] 音阶正确回绕到 0（共 8 个音）");
        else begin
            $display("  [FAIL] 回绕后 scale_pos = %0d，期望 0", dut.scale_pos);
            errors = errors + 1;
        end

        // ===== 检查5：I2S 活动 =====
        $display("[检查5] I2S 信号活动");
        begin : chk_i2s
            integer toggles;
            toggles = 0;
            for (integer i = 0; i < 20000; i = i + 1) begin
                @(posedge clk);
                if (i2s_bck) toggles = toggles + 1;
            end
            if (toggles > 1000) $display("  [PASS] BCK 正常翻转（%0d 次）", toggles);
            else begin $display("  [FAIL] BCK 几乎不翻转（%0d 次）", toggles); errors = errors + 1; end
        end

        if (pa_en === 1'b1) $display("  [PASS] 功放使能已拉高");
        else begin $display("  [FAIL] pa_en = %b", pa_en); errors = errors + 1; end

        // ===== 检查6：LED 心跳 =====
        $display("[检查6] LED 心跳");
        begin : chk_led
            reg led0_a, led0_b;
            led0_a = led[0];
            repeat (3000000) @(negedge clk);
            led0_b = led[0];
            if (led0_a !== led0_b) $display("  [PASS] led[0] 在闪烁（心跳正常）");
            else begin $display("  [FAIL] led[0] 未变化"); errors = errors + 1; end
        end

        $display("==================================================");
        if (errors == 0) $display("  全部通过：0 个错误");
        else             $display("  验证失败：%0d 个错误", errors);
        $display("==================================================");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 80000000);
        $display("[ERROR] 仿真超时");
        $finish;
    end

endmodule
