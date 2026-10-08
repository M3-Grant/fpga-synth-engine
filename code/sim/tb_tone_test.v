// ============================================================================
//  测试平台 : tb_tone_test.v
//  被测模块 : tone_test_top（生死线验证工程）
//  检查    : 上电复位结束后，相位累加器 MSB 的翻转频率是否等于设定音高
//            只在 rst_n 拉高之后才开始计数，避免把 X→0 的初始跳变算进去
// ============================================================================
`timescale 1ns / 1ps

module tb_tone_test;

    localparam CLK_PERIOD = 37.037;
    localparam FS         = 27000000.0 / 8.0 / 64.0;   // 52734.375 Hz
    localparam SIM_CLK    = 1200000;                   // 约 44 ms

    reg clk;
    wire i2s_bck, i2s_lrck, i2s_din;
    wire [5:0] led;

    tone_test_top #(.FCW(32'd35835935)) dut (
        .clk(clk),
        .i2s_bck(i2s_bck), .i2s_lrck(i2s_lrck), .i2s_din(i2s_din),
        .led(led)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    integer edges, samples, errors;
    time    t_first, t_last;
    real    freq;
    reg     armed;

    initial begin
        edges = 0; samples = 0; errors = 0;
        t_first = 0; t_last = 0; armed = 1'b0;
    end

    always @(posedge dut.rst_n) armed = 1'b1;

    always @(posedge i2s_lrck) samples = samples + 1;

    always @(dut.phase[31]) begin
        if (armed) begin
            edges = edges + 1;
            if (edges == 1) t_first = $time;
            else            t_last  = $time;
        end
    end

    initial begin
        #(CLK_PERIOD * SIM_CLK);

        $display("========================================");
        $display("  tone_test_top 仿真验证");
        $display("========================================");
        $display("  实际采样率 fs   = %.3f Hz", FS);
        $display("  音频样本数      = %0d", samples);
        $display("  相位 MSB 翻转数 = %0d", edges);

        if (edges > 4) begin
            freq = (edges - 1) / 2.0 / ((t_last - t_first) / 1.0e9);
        end else begin
            freq = 0.0;
        end

        $display("  测得方波频率    = %.2f Hz  (期望 440.00 Hz)", freq);

        if (freq > 439.0 && freq < 441.0) begin
            $display("  [PASS] 音高正确（误差 < 0.25%%）");
        end else begin
            $display("  [FAIL] 音高偏差过大 —— 检查 FCW 是否按 fs=52734.375 计算");
            errors = errors + 1;
        end

        if (samples > 1000) begin
            $display("  [PASS] I2S 持续输出（%0d 个样本）", samples);
        end else begin
            $display("  [FAIL] I2S 没有输出");
            errors = errors + 1;
        end

        $display("========================================");
        if (errors == 0) $display("  全部通过：0 个错误");
        else             $display("  验证失败：%0d 个错误", errors);
        $display("========================================");
        $finish;
    end

endmodule
