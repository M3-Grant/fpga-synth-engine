`timescale 1ns / 1ps
// 逐周期追踪：load 之后的每个 bck_fall，din 与 stream_dbg 的变化
module tb_diag3;

    localparam CLK_PERIOD = 37.037;
    reg  clk, rst_n, sample_en;
    reg  [15:0] sample_l, sample_r;
    wire bck, lrck, din;

    i2s_tx #(.DATA_BITS(16), .BCK_DIV(8)) dut (
        .clk(clk), .rst_n(rst_n), .sample_en(sample_en),
        .sample_l(sample_l), .sample_r(sample_r),
        .bck(bck), .lrck(lrck), .din(din)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    integer n;
    initial begin
        rst_n = 0; sample_en = 0;
        sample_l = 16'h1234; sample_r = 16'hABCD;
        #(CLK_PERIOD*20); rst_n = 1;
        #(CLK_PERIOD*50);

        // 等一个 load
        @(posedge clk);
        wait (dut.load == 1'b1);
        $display("=== 检测到 load ===");
        $display("load 时刻: din=%b  shift_reg=%h  sample_l=%h",
                 din, dut.shift_reg, sample_l);

        for (n = 0; n < 34; n = n + 1) begin
            @(posedge clk);
            if (dut.bck_fall) begin
                $display("bck_fall #%0d: din=%b  shift_reg=%h  dbg_cnt=%0d  stream_dbg=%h",
                         n, din, dut.shift_reg, dut.dbg_cnt, dut.stream_dbg);
            end
        end
        $finish;
    end

endmodule
