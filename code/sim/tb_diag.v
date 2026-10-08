`timescale 1ns / 1ps
// 最小诊断：统计 LRCK 每个电平期间包含多少个 BCK 周期
module tb_diag;

    localparam CLK_PERIOD = 37.037;
    localparam DATA_BITS  = 16;
    localparam BCK_DIV    = 8;

    reg  clk, rst_n, sample_en;
    reg  [15:0] sample_l, sample_r;
    wire bck, lrck, din;

    integer bck_per_level;
    integer level_count;
    time    t_lrck_change;

    i2s_tx #(.DATA_BITS(DATA_BITS), .BCK_DIV(BCK_DIV)) dut (
        .clk(clk), .rst_n(rst_n), .sample_en(sample_en),
        .sample_l(sample_l), .sample_r(sample_r),
        .bck(bck), .lrck(lrck), .din(din)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // 统计：每个 LRCK 电平期间数 BCK 下降沿
    initial begin
        bck_per_level = 0;
        level_count   = 0;
        forever begin
            @(negedge bck);
            bck_per_level = bck_per_level + 1;
        end
    end

    // 在 LRCK 每次变化时打印统计
    always @(lrck) begin
        if (rst_n) begin
            level_count = level_count + 1;
            $display("t=%0t  LRCK 变为 %b，上一个电平期间 BCK 下降沿数 = %0d",
                     $time, lrck, bck_per_level);
            bck_per_level = 0;
            if (level_count >= 6) $finish;
        end
    end

    initial begin
        rst_n     = 0;
        sample_en = 0;
        sample_l  = 16'h1234;
        sample_r  = 16'hABCD;
        #(CLK_PERIOD * 20);
        rst_n = 1;
        $display("=== 复位释放，开始统计 ===");
        #(CLK_PERIOD * 20000);
        $display("=== 统计结束 ===");
        $finish;
    end

endmodule
