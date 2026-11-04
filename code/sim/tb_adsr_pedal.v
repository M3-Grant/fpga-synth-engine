// ============================================================================
//  tb_adsr_pedal.v —— 验证"踩着延音踏板松手"时数字波形包的慢衰减
//
//  场景（对应 synth_ttp229_top 的门控）：
//    note_valid 被门控 → note_alloc 收不到松键 → voice_busy 保持 1
//    所以 adsr 的 note_on / gate 一直是 1，唯一变化的是 key_held
//
//  期望：
//    key_held=1 时 env 停在 SUS_LEVEL(160)
//    key_held=0（踩踏板松手）时 env 按 env/16+1 指数式下降，约 0.9 s 归零
//
//  运行：iverilog -o tb_adsr_pedal.vvp tb_adsr_pedal.v ../rtl/adsr.v && vvp tb_adsr_pedal.vvp
// ============================================================================
`timescale 1ns / 1ps

module tb_adsr_pedal;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         sample_en = 0;
    reg         trig = 0;
    reg         note_on = 1;
    reg         gate = 1;
    reg         fast_release = 0;
    reg         sustain = 1;
    reg         key_held = 1;
    wire [7:0]  env;

    always #18.5 clk = ~clk;      // 27 MHz

    // 采样使能：每 512 个时钟一个（≈ 52734 Hz）
    integer clk_div = 0;
    always @(posedge clk) begin
        if (clk_div == 511) begin
            clk_div   <= 0;
            sample_en <= 1'b1;
        end
        else begin
            clk_div   <= clk_div + 1;
            sample_en <= 1'b0;
        end
    end

    adsr #(
        .ENV_BITS  (8),
        .SUS_LEVEL (8'd160),
        .ATK_STEP  (8'd8),
        .DEC_STEP  (8'd2),
        .REL_STEP  (8'd3)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_en    (sample_en),
        .trig         (trig),
        .note_on      (note_on),
        .gate         (gate),
        .fast_release (fast_release),
        .sustain      (sustain),
        .key_held     (key_held),
        .env          (env)
    );

    integer n_sample = 0;
    always @(posedge clk) if (sample_en) n_sample <= n_sample + 1;

    integer i;
    integer t_sustain = 0;
    integer t_zero    = -1;
    real    ms = 1000.0 / 52734.375;

    initial begin
        $display("=== adsr pedal-decay test (unit: samples @52734 Hz) ===");
        rst_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (20) @(posedge clk);

        // ---- 1. 起音：一个 trig 脉冲 ----
        @(posedge clk);
        trig <= 1'b1;
        @(posedge clk);
        trig <= 1'b0;

        // ---- 2. 等 200 个采样，包络应停在 SUS_LEVEL ----
        wait (n_sample == 200);
        $display("[1] after attack: env=%0d at sample %0d (%.1f ms)",
                 env, n_sample, n_sample * ms);
        if (env !== 8'd160) begin
            $display("[FAIL] sustain level expected 160, got %0d", env);
            $fatal(1);
        end
        t_sustain = n_sample;

        // ---- 3. 踩踏板松手 ----
        key_held <= 1'b0;
        $display("[2] key released while pedal down at sample %0d", n_sample);

        // 每 16384 采样打印一次包络
        for (i = 0; i < 200; i = i + 1) begin
            wait (n_sample > t_sustain + (i + 1) * 16384);
            $display("    +%0.1f ms : env=%0d", (n_sample - t_sustain) * ms, env);
            if (env === 8'd0) begin
                t_zero = n_sample;
                i = 200;
            end
        end

        if (t_zero < 0) begin
            $display("[FAIL] envelope never reached 0");
            $fatal(1);
        end

        $display("[3] envelope reached 0 at +%0.1f ms after key release",
                 (t_zero - t_sustain) * ms);

        if (((t_zero - t_sustain) * ms) > 600.0 &&
            ((t_zero - t_sustain) * ms) < 1600.0) begin
            $display("[PASS] pedal release decay in 600..1600 ms");
        end
        else begin
            $display("[FAIL] decay time out of range");
            $fatal(1);
        end

        // ---- 4. 不踩踏板：松键应快速收尾（fade_soft=1 → 约 48 ms）----
        $display("--- case 2: no pedal, plain key release ---");
        rst_n = 0;
        repeat (20) @(posedge clk);
        sustain  = 0;
        key_held = 1;
        note_on  = 1;
        gate     = 1;
        rst_n    = 1;
        repeat (20) @(posedge clk);

        @(posedge clk);
        trig <= 1'b1;
        @(posedge clk);
        trig <= 1'b0;

        wait (env === 8'd160);
        t_sustain = n_sample;
        note_on <= 1'b0;                 // 真正的松键（note_valid 没有被门控）
        wait (env === 8'd0);
        $display("[4] plain release without pedal: %0.1f ms",
                 (n_sample - t_sustain) * ms);
        if (((n_sample - t_sustain) * ms) < 60.0)
            $display("[PASS] quick release unchanged");
        else begin
            $display("[FAIL] plain release too slow (should still be ~48 ms)");
            $fatal(1);
        end

        $display("ALL CHECKS PASSED");
        $finish;
    end

endmodule
