// ============================================================================
//  测试平台 : tb_ttp229.v
//  被测模块 : ttp229_scan（TTP229 2 线串行读出的主机侧）
//
//  策略     : 用一个"虚拟 TTP229"在 SCL 下降沿后逐位输出数据（MSB first），
//             与真实模块的时序一致；扫描器在 SCL 低电平末尾采样。
//             参数缩短以便快速仿真（GAP/SYNC/SCL_HALF 按比例缩小）。
//
//  检查项   : ① 复位后键状态为 0
//             ② 单键（key[3]）能被正确读出
//             ③ 最低位（key[0]）与最高位（key[15]）都能对上（验证位序）
//             ④ 全按 / 全松都能正确反映
//             ⑤ key_valid 每轮扫描出现一次
// ============================================================================
`timescale 1ns / 1ps

module tb_ttp229;

    localparam CLK_PERIOD = 37.037;
    localparam KEY_NUM    = 16;
    localparam SYNC_CNT   = 100;
    localparam SCL_HALF   = 5;
    localparam GAP_CNT    = 200;
    // 一轮扫描的时钟数：GAP + SYNC + KEY_NUM × 2 × SCL_HALF
    localparam SCAN_CLKS  = GAP_CNT + SYNC_CNT + KEY_NUM * 2 * SCL_HALF;

    reg         clk, rst_n;
    reg         sdo;
    wire        scl;
    wire [KEY_NUM-1:0] key_state;
    wire        key_valid;

    ttp229_scan #(
        .KEY_NUM   (KEY_NUM),
        .SYNC_CNT  (SYNC_CNT),
        .SCL_HALF  (SCL_HALF),
        .GAP_CNT   (GAP_CNT),
        .MSB_FIRST (1)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .sdo       (sdo),
        .scl       (scl),
        .key_state (key_state),
        .key_valid (key_valid)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ==================================================================
    // 虚拟 TTP229：SCL 第 1 个下降沿是同步，之后 16 个下降沿逐位输出
    // ==================================================================
    reg [15:0] fake_keys = 16'h0000;
    integer    scl_falls = 0;
    integer    rem;
    integer    valid_cnt = 0;

    always @(negedge scl) begin
        scl_falls = scl_falls + 1;
        rem = scl_falls % (KEY_NUM + 1);        // 17 个沿为一轮
        if (rem >= 2)
            sdo <= fake_keys[KEY_NUM + 1 - rem];   // 第 1 位是最高位
        else if (rem == 0)
            sdo <= fake_keys[0];                   // 最后一位是最低位
        // rem == 1 → 同步沿，SDO 保持不变
    end

    always @(posedge clk) if (key_valid) valid_cnt = valid_cnt + 1;

    // ==================================================================
    // 检查
    // ==================================================================
    integer errors;

    task chk;
        input [255:0] tag;
        input [0:0]   cond;
        begin
            if (cond) $display("  [PASS] %0s", tag);
            else begin
                $display("  [FAIL] %0s", tag);
                errors = errors + 1;
            end
        end
    endtask

    task wait_scan;
        begin
            // 必须等 2 轮：fake_keys 改变时可能正扫到一半，
            // 只等 1 轮会读到"旧数据 + 新数据"的混合值
            repeat (SCAN_CLKS * 2 + 50) @(posedge clk);
        end
    endtask

    initial begin
        errors    = 0;
        rst_n     = 1'b0;
        sdo       = 1'b0;
        fake_keys = 16'h0000;

        repeat (50) @(posedge clk);
        rst_n = 1'b1;

        $display("==================================================");
        $display("  ttp229_scan simulation (KEY_NUM=%0d, MSB first)", KEY_NUM);
        $display("==================================================");

        // ---- 1. 复位后全松 ----
        wait_scan;
        chk("idle: key_state == 0", key_state == 16'h0000);

        // ---- 2. 单键 key[3] ----
        fake_keys = 16'h0008;
        wait_scan;
        $display("    expected 0008, got %h", key_state);
        chk("key[3] only", key_state == 16'h0008);

        // ---- 3. 最低位 key[0]（验证位序没反）----
        fake_keys = 16'h0001;
        wait_scan;
        chk("key[0] only (bit order low)", key_state == 16'h0001);

        // ---- 4. 最高位 key[15] ----
        fake_keys = 16'h8000;
        wait_scan;
        chk("key[15] only (bit order high)", key_state == 16'h8000);

        // ---- 5. 全按 ----
        fake_keys = 16'hFFFF;
        wait_scan;
        $display("    expected FFFF, got %h", key_state);
        chk("all pressed", key_state == 16'hFFFF);

        // ---- 6. 松开后回到 0 ----
        fake_keys = 16'h0000;
        wait_scan;
        chk("all released", key_state == 16'h0000);

        // ---- 7. key_valid 应该有多次 ----
        chk("key_valid fired several times", valid_cnt > 3);

        $display("==================================================");
        if (errors == 0) $display("  ALL CHECKS PASSED");
        else             $display("  %0d CHECK(S) FAILED", errors);
        $display("==================================================");
        $finish;
    end

endmodule
