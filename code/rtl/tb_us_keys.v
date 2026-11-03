`timescale 1ns / 1ps

// 验证 uart_stream 内部的 12 音计数器是否真的会累加
module tb_us_keys;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         sample_en = 0;
    reg  signed [15:0] sample = 0;
    reg  [2:0]  timbre = 4;
    reg  [11:0] keys = 0;
    reg  [2:0]  voices = 0;
    
    reg  [31:0] lat_last = 0, lat_min = 32'hFFFFFFFF, lat_max = 0, lat_sum = 0;
    reg  [15:0] lat_cnt = 0;
    reg         lat_valid = 0;
    reg  [15:0] hist0 = 0;

    wire uart_txd, frame_busy;

    uart_stream #(
        .FRAME_LEN (576)
    ) u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_en  (sample_en),
        .audio      (sample),
        .timbre     (timbre),
        .keys       (keys),
        .voices     (voices),

        .lat_last   (lat_last),
        .lat_min    (lat_min),
        .lat_max    (lat_max),
        .lat_sum    (lat_sum),
        .lat_cnt    (lat_cnt),
        .lat_valid  (lat_valid),
        .hist0      (hist0), .hist1 (16'd0), .hist2 (16'd0), .hist3 (16'd0),
        .hist4      (16'd0), .hist5 (16'd0), .hist6 (16'd0), .hist7 (16'd0),
        .hist8      (16'd0), .hist9 (16'd0), .hist10(16'd0), .hist11(16'd0),
        .hist12     (16'd0), .hist13(16'd0), .hist14(16'd0), .hist15(16'd0),
        .uart_tx    (uart_txd),
        .frame_busy (frame_busy)
    );

    always #18.5 clk = ~clk;   // 27 MHz

    // 每 20 us 产生一个 sample_en（近似 52.7 kHz）
    initial begin
        forever begin
            #20000 sample_en = 1;
            #18.5 sample_en = 0;
            #19000;
        end
    end

    initial begin
        #100 rst_n = 1;
        #1000;

        // 模拟按 C4（keys[0]）三次：高-低-高-低...
        repeat (3) begin
            keys = 12'b000000000001;   // 按下 C4
            #500000;
            keys = 12'b000000000000;   // 松开
            #500000;
        end

        // 再按 E4（keys[4]）两次
        repeat (2) begin
            keys = 12'b000000010000;
            #500000;
            keys = 12'b000000000000;
            #500000;
        end

        #2000000;
        $display("内部计数器: nc0=%0d nc1=%0d nc4=%0d (期望 3 / 0 / 2)", u_dut.nc0, u_dut.nc1, u_dut.nc4);
        $finish;
    end

endmodule
