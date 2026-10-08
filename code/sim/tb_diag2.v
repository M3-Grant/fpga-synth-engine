`timescale 1ns / 1ps
// 在每个帧边界（load_l）报告上一帧采到的 32 位数据
module tb_diag2;

    localparam CLK_PERIOD = 37.037;
    reg  clk, rst_n, sample_en;
    reg  [15:0] sample_l, sample_r;
    wire bck, lrck, din;

    i2s_tx #(.DATA_BITS(16), .BCK_DIV(8), .DEBUG(1)) dut (
        .clk(clk), .rst_n(rst_n), .sample_en(sample_en),
        .sample_l(sample_l), .sample_r(sample_r),
        .bck(bck), .lrck(lrck), .din(din)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // 在 load_l 上升沿报告上一帧采集到的完整数据
    reg load_l_d = 0;
    always @(posedge clk) begin
        load_l_d <= dut.load_l;
        if (dut.load_l && !load_l_d) begin
            $display("  上一帧采样 = %h", dut.gen_debug.stream_dbg);
        end
    end

    integer n;
    initial begin
        rst_n = 0; sample_en = 0;
        sample_l = 16'h1234; sample_r = 16'hABCD;
        #(CLK_PERIOD*20); rst_n = 1;
        $display("=== 样本 L=1234 R=ABCD（期望 1234abcd）===");
        #(CLK_PERIOD * 2600);

        sample_l = 16'hFFFF; sample_r = 16'h0000;
        $display("=== 样本 L=FFFF R=0000（期望 ffff0000）===");
        #(CLK_PERIOD * 2600);

        sample_l = 16'h8001; sample_r = 16'h7FFE;
        $display("=== 样本 L=8001 R=7FFE（期望 80017ffe）===");
        #(CLK_PERIOD * 2600);

        sample_l = 16'hA55A; sample_r = 16'h5AA5;
        $display("=== 样本 L=A55A R=5AA5（期望 a55a5aa5）===");
        #(CLK_PERIOD * 2600);

        $finish;
    end

    initial begin
        #(CLK_PERIOD * 100000);
        $display("[ERROR] 超时");
        $finish;
    end

endmodule
