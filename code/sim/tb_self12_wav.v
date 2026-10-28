// ============================================================================
//  测试平台 : tb_self12_wav.v
//  被测模块 : self_test_12notes（十二音循环自检固件）
//  目的     : 把上板固件的数字输出原样导出来，判断"失真"是数字侧还是硬件侧
//
//  导出 self12_dump.txt（每行一个 16 位有符号样本），再用 tools/txt_to_wav.py
//  转成 WAV。若 WAV 干净、上板失真 → 硬件（功放/喇叭/pa_en 时序）；
//  若 WAV 也不对 → 是 RTL bug。
//
//  只跑第一个音（C4，按住 0.6 s）+ 0.2 s 释放，约 42187 个采样。
// ============================================================================
`timescale 1ns / 1ps

module tb_self12_wav;

    localparam CLK_PERIOD = 37.037;
    localparam N_SAMP     = 42187;      // 0.8 s @ 52734.375 Hz

    reg clk, rst_n;

    wire        i2s_bck, i2s_lrck, i2s_din;
    wire        pa_en;
    wire [5:0]  led;

    self_test_12notes #(
        .BCK_HALF  (4),
        .HOLD_CLK  (32'd16_200_000),    // 0.60 s
        .GAP_CLK   (32'd8_100_000),     // 0.30 s
        .NOTE_NUM  (12)
    ) dut (
        .clk      (clk),
        .i2s_bck  (i2s_bck),
        .i2s_lrck (i2s_lrck),
        .i2s_din  (i2s_din),
        .pa_en    (pa_en),
        .led      (led)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- 在 sample_req 后第 30 拍取稳定输出 ----
    reg [5:0] snag;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                       snag <= 6'd0;
        else if (dut.u_i2s.sample_req)    snag <= 6'd0;
        else if (snag < 6'd40)            snag <= snag + 6'd1;
    end

    integer fd;
    integer idx;
    integer peak;

    always @(posedge clk) begin
        if (snag == 6'd30 && idx < N_SAMP) begin
            $fwrite(fd, "%0d\n", dut.audio);
            if (dut.audio > peak)  peak = dut.audio;
            if (-dut.audio > peak) peak = -dut.audio;
            idx = idx + 1;
        end
    end

    initial begin
        fd    = $fopen("self12_dump.txt", "w");
        if (fd == 0) begin
            $display("[ERROR] cannot open self12_dump.txt");
            $finish;
        end

        idx   = 0;
        peak  = 0;
        rst_n = 1'b0;

        repeat (200) @(posedge clk);
        rst_n = 1'b1;

        wait (idx >= N_SAMP);
        repeat (10) @(posedge clk);
        $fclose(fd);

        $display("==================================================");
        $display("  self12_dump.txt written");
        $display("  samples = %0d  (%.3f s)", idx, idx / 52734.375);
        $display("  peak    = %0d / 32767  (%.1f%%)", peak, peak * 100.0 / 32767.0);
        $display("  pa_en   = %b", pa_en);
        $display("==================================================");
        $finish;
    end

endmodule
