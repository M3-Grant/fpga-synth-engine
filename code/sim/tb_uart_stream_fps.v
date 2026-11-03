// ============================================================================
//  tb_uart_stream_fps.v -- measure the UART frame period of uart_stream.v
//
//  Drives sample_en at the real audio rate (27 MHz / 512 = 52734.375 Hz) and
//  time-stamps every frame start (state==S_LOAD with byte_idx==0).
//
//  Expectations with DECIM=7:
//    - one frame needs 512*7 = 3584 audio samples = 3584*512 clk = 68.0 ms
//    - transmitting 576 bytes @115200 takes 50.0 ms
//    - pipelined (ping-pong) -> period = max(68, 50) = 68 ms  -> 14.7 fps
//  With the old non-pipelined design the period was 68+50 = 118 ms -> 8.5 fps.
// ============================================================================
`timescale 1ns / 1ps

module tb_uart_stream_fps;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    reg  sample_en = 1'b0;
    reg  signed [15:0] audio = 16'sd0;

    wire uart_tx, frame_busy;

    // 27 MHz
    always #18.5185 clk = ~clk;

    // audio-rate pulse: every 512 clocks
    integer div_cnt = 0;
    always @(posedge clk) begin
        if (div_cnt == 511) begin div_cnt <= 0; sample_en <= 1'b1; end
        else                begin div_cnt <= div_cnt + 1; sample_en <= 1'b0; end
    end

    // a slow ramp so the payload is not all identical
    integer samp = 0;
    always @(posedge clk) if (sample_en) begin
        samp <= samp + 1;
        audio <= audio + 16'sd7;
    end

    uart_stream #(
        .CLK_HZ (27_000_000),
        .BAUD   (115200),
        .DECIM  (7)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_en  (sample_en),
        .audio      (audio),
        .keys       (12'h001),
        .timbre     (3'd4),
        .voices     (3'd1),
        .uart_tx    (uart_tx),
        .frame_busy (frame_busy),
        .lat_last   (32'd135000),
        .lat_min    (32'd135000),
        .lat_max    (32'd135000),
        .lat_sum    (32'd135000),
        .lat_cnt    (16'd1),
        .lat_valid  (1'b1),
        .hist0      (16'd0), .hist1 (16'd0), .hist2 (16'd0), .hist3 (16'd0),
        .hist4      (16'd0), .hist5 (16'd0), .hist6 (16'd0), .hist7 (16'd0),
        .hist8      (16'd0), .hist9 (16'd0), .hist10(16'd0), .hist11(16'd0),
        .hist12     (16'd0), .hist13(16'd0), .hist14(16'd0), .hist15(16'd0)
    );

    // ---------------------------------------------------------------
    // frame start detection (hierarchical reference into the DUT)
    // ---------------------------------------------------------------
    reg  frame_start_d = 1'b0;
    integer frame_cnt = 0;
    realtime t_prev = 0.0;
    realtime t_now;
    real min_gap_ms = 1.0e9;
    real max_gap_ms = 0.0;

    always @(posedge clk) begin
        frame_start_d <= (dut.state == 2'd1) && (dut.byte_idx == 10'd0);
        if (frame_start_d) begin
            t_now = $realtime / 1.0e6;          // ns -> ms
            frame_cnt = frame_cnt + 1;
            if (frame_cnt > 1) begin
                if (t_now - t_prev < min_gap_ms) min_gap_ms = t_now - t_prev;
                if (t_now - t_prev > max_gap_ms) max_gap_ms = t_now - t_prev;
            end
            $display("  frame %0d  at %10.3f ms  (gap %8.3f ms)",
                     frame_cnt, t_now, (frame_cnt > 1) ? (t_now - t_prev) : 0.0);
            t_prev = t_now;
        end
    end

    // ---------------------------------------------------------------
    initial begin
        $display("=== tb_uart_stream_fps (DECIM=7) ===");
        repeat (20) @(posedge clk);
        rst_n = 1'b1;

        // run long enough for ~8 frames (8 * 68 ms = 544 ms)
        #600_000_000;   // 600 ms in ns

        $display("");
        $display("frames transmitted : %0d", frame_cnt);
        if (frame_cnt >= 2) begin
            $display("frame period min   : %0.3f ms  (%.2f fps)", min_gap_ms, 1000.0/min_gap_ms);
            $display("frame period max   : %0.3f ms  (%.2f fps)", max_gap_ms, 1000.0/max_gap_ms);
            // expect 68 ms (pipelined); fail if still ~118 ms (old design)
            if (max_gap_ms < 75.0)  $display("[PASS] pipelined frame period (%.1f ms < 75 ms)", max_gap_ms);
            else                    $display("[FAIL] frame period %.1f ms - not pipelined?", max_gap_ms);
        end
        else begin
            $display("[FAIL] only %0d frame(s) in 600 ms", frame_cnt);
        end
        $finish;
    end

endmodule
