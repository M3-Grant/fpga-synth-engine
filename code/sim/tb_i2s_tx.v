// ============================================================================
//  测试平台 : tb_i2s_tx.v   （v5 · 配合标准 I2S 时序重写）
//  被测模块 : i2s_tx
//
//  采集要点（v1 踩坑的地方）：
//    1. I2S 规定 LRCK 跳变后的第 1 个 BCK 上升沿是无效位 —— 必须丢弃
//    2. 之后连续 16 个上升沿才是 D15..D0
//    3. 再之后 15 个上升沿是补零，也应跳过
//  旧 testbench 没有丢掉第一位，所以采到的永远是"期望值左移 1 位"。
//
//  另外：样本必须在 sample_req 时更新，不能随便在时钟沿改，
//        否则会跟模块内部的锁存打擂台，出现随机错值。
// ============================================================================
`timescale 1ns / 1ps

module tb_i2s_tx;

    localparam CLK_PERIOD = 37.037;   // 27 MHz
    localparam DATA_BITS  = 16;
    localparam BCK_HALF   = 4;        // BCK = 27M/8 = 3.375 MHz
    localparam FS         = 27000000.0 / (2.0 * BCK_HALF) / 64.0;

    reg  clk, rst_n;
    reg  [15:0] sample_l, sample_r;
    wire bck, lrck, din, sample_req;

    integer errors;

    i2s_tx #(.DATA_BITS(DATA_BITS), .BCK_HALF(BCK_HALF)) dut (
        .clk(clk), .rst_n(rst_n),
        .sample_l(sample_l), .sample_r(sample_r),
        .bck(bck), .lrck(lrck), .din(din), .sample_req(sample_req)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ------------------------------------------------------------------
    // 频率统计
    // ------------------------------------------------------------------
    integer bck_falls, lrck_falls;
    integer bck_at_last_lrck, bck_in_lrck;
    time    t_lrck_prev, t_bck_prev;
    real    lrck_period, bck_period;

    initial begin
        bck_falls = 0; lrck_falls = 0;
        bck_at_last_lrck = 0; bck_in_lrck = 0;
        t_lrck_prev = 0; t_bck_prev = 0;
        lrck_period = 0.0; bck_period = 0.0;
    end

    always @(negedge bck) begin
        bck_falls = bck_falls + 1;
        bck_period = ($time - t_bck_prev) / 1.0;
        t_bck_prev = $time;
    end

    always @(negedge lrck) begin
        lrck_falls = lrck_falls + 1;
        if (lrck_falls > 1) begin
            lrck_period = ($time - t_lrck_prev) / 1.0;
            bck_in_lrck = bck_falls - bck_at_last_lrck;
        end
        bck_at_last_lrck = bck_falls;
        t_lrck_prev      = $time;
    end

    // ------------------------------------------------------------------
    // 串行流采集：LRCK 下降沿 → 丢 1 位 → 采 16 位 → 跳 15 位补零
    //             LRCK 上升沿 → 同样处理右声道
    // 整帧收齐后一次性写入 cap_frame，并打一个 cap_valid 脉冲
    // ------------------------------------------------------------------
    reg [31:0] cap_frame;
    reg        cap_valid;

    initial begin
        cap_frame = 32'd0;
        cap_valid = 1'b0;
    end

    task capture_frame;
        integer k;
        reg [15:0] l, r;
        begin
            @(negedge lrck);
            @(posedge bck);                                  // 无效位，丢弃
            for (k = 0; k < 16; k = k + 1) begin
                @(posedge bck);
                l = {l[14:0], din};
            end
            for (k = 0; k < 15; k = k + 1) @(posedge bck);   // 补零

            @(posedge lrck);
            @(posedge bck);                                  // 无效位，丢弃
            for (k = 0; k < 16; k = k + 1) begin
                @(posedge bck);
                r = {r[14:0], din};
            end
            for (k = 0; k < 15; k = k + 1) @(posedge bck);   // 补零

            cap_frame = {l, r};
            cap_valid = 1'b1;
            @(posedge clk);
            cap_valid = 1'b0;
        end
    endtask

    initial begin
        forever capture_frame();
    end

    // ------------------------------------------------------------------
    task check_stream;
        input [15:0]  l;
        input [15:0]  r;
        input [255:0] tag;
        integer n;
        begin
            @(posedge sample_req);     // 在模块给出的安全点更新样本
            @(posedge clk);
            sample_l = l;
            sample_r = r;
            for (n = 0; n < 2; n = n + 1) @(posedge cap_valid);  // 等两帧稳定
            if (cap_frame !== {l, r}) begin
                $display("  [FAIL] %0s  采到 %h  期望 %h", tag, cap_frame, {l, r});
                errors = errors + 1;
            end
            else begin
                $display("  [PASS] %0s  流=%h", tag, cap_frame);
            end
        end
    endtask

    // ------------------------------------------------------------------
    initial begin
        $dumpfile("tb_i2s_tx.vcd");
        $dumpvars(0, tb_i2s_tx);

        errors    = 0;
        rst_n     = 1'b0;
        sample_l  = 16'h0000;
        sample_r  = 16'h0000;

        #(CLK_PERIOD * 20);
        rst_n = 1'b1;
        #(CLK_PERIOD * 20);

        $display("========================================");
        $display("  i2s_tx 仿真验证 (v5 · 标准 I2S)");
        $display("========================================");

        #(CLK_PERIOD * 40000);

        // ---- 检查1：BCK 周期 ----
        $display("[检查1] BCK 周期（期望 %.1f ns）", CLK_PERIOD * 2 * BCK_HALF);
        $display("        实测 = %.1f ns", bck_period);
        if (bck_period > CLK_PERIOD*2*BCK_HALF*0.98 &&
            bck_period < CLK_PERIOD*2*BCK_HALF*1.02) begin
            $display("        [PASS]");
        end else begin
            $display("        [FAIL]"); errors = errors + 1;
        end

        // ---- 检查2：一个 LRCK 周期内的 BCK 数（应为 64）----
        $display("[检查2] 一个 LRCK 周期内的 BCK 数（应为 64）");
        $display("        实测 = %0d 个", bck_in_lrck);
        if (bck_in_lrck >= 63 && bck_in_lrck <= 65) begin
            $display("        [PASS]");
        end else begin
            $display("        [FAIL]"); errors = errors + 1;
        end

        // ---- 检查3：实际采样率 ----
        $display("[检查3] 实际采样率（期望 %.1f Hz）", FS);
        $display("        实测 = %.1f Hz", 1.0e9 / lrck_period);
        if (lrck_period > 0 &&
            (1.0e9/lrck_period) > FS*0.98 &&
            (1.0e9/lrck_period) < FS*1.02) begin
            $display("        [PASS]");
        end else begin
            $display("        [FAIL]"); errors = errors + 1;
        end

        // ---- 检查4：串行数据 ----
        $display("[检查4] 串行数据流（左 MSB-first + 右 MSB-first）");
        check_stream(16'h1234, 16'hABCD, "T1 L=1234 R=ABCD");
        check_stream(16'hFFFF, 16'h0000, "T2 L=FFFF R=0000");
        check_stream(16'h8001, 16'h7FFE, "T3 L=8001 R=7FFE");
        check_stream(16'hA55A, 16'h5AA5, "T4 L=A55A R=5AA5");
        check_stream(16'h0001, 16'h8000, "T5 L=0001 R=8000");
        check_stream(16'h7FFF, 16'h8000, "T6 L=+max R=-max");

        $display("========================================");
        if (errors == 0) $display("  全部通过：0 个错误");
        else             $display("  验证失败：%0d 个错误", errors);
        $display("========================================");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 600000);
        $display("[ERROR] 仿真超时");
        $finish;
    end

endmodule
