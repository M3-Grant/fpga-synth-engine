// ============================================================================
//  测试平台 : tb_led_ctrl_top.v
//  被测模块 : led_ctrl_top（FAST_SIM=1，时基缩短，便于快速仿真）
//  验证内容 : 1) 复位后进入模式0
//             2) 依次按键可切换到模式1~4
//             3) 模式循环（模式4后再按回到模式0）
//             4) 各模式下 LED 输出符合预期（低电平点亮）
//  运行方法 : iverilog -g2005 -o sim.out rtl/*.v sim/tb_led_ctrl_top.v
//             vvp sim.out
// ============================================================================
`timescale 1ns / 1ps

module tb_led_ctrl_top;

    localparam CLK_PERIOD = 37.037;   // 27MHz ≈ 37ns

    reg        clk;
    reg        rst_n;
    reg        key;
    wire [5:0] led;

    integer    errors;
    integer    i;

    // ---- 被测模块（FAST_SIM=1：时基缩短到几十个时钟）----
    led_ctrl_top #(
        .FAST_SIM (1)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .key   (key),
        .led   (led)
    );

    // ---- 时钟生成 ----
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ------------------------------------------------------------------
    // 等待一个消抖周期（FAST_SIM 下 CNT_DEBOUNCE = 4）
    // ------------------------------------------------------------------
    task wait_debounce;
        begin
            #(CLK_PERIOD * 20);
        end
    endtask

    // ------------------------------------------------------------------
    // 按一次键
    // ------------------------------------------------------------------
    task press_key;
        begin
            key = 1'b1;
            wait_debounce;
            key = 1'b0;
            wait_debounce;
        end
    endtask

    // ------------------------------------------------------------------
    // 切换模式并校验（不依赖消抖时序，直接设置模式后观察输出）
    //   mode_val : 目标模式
    //   exp_led  : 期望的 led 端口值（低电平点亮，故为 ~图案）
    // ------------------------------------------------------------------
    task check_mode;
        input [2:0] mode_val;
        input [5:0] exp_led;
        input [8*16-1:0] name;
        begin
            force dut.mode = mode_val;
            #(CLK_PERIOD * 5);
            if (led !== exp_led) begin
                $display("  [FAIL] mode%0d (%0s): led=%b, expected %b",
                         mode_val, name, led, exp_led);
                errors = errors + 1;
            end
            else begin
                $display("  [PASS] mode%0d (%0s): led=%b", mode_val, name, led);
            end
            release dut.mode;
            #(CLK_PERIOD * 2);
        end
    endtask

    // ------------------------------------------------------------------
    // 主流程
    // ------------------------------------------------------------------
    initial begin
        $dumpfile("tb_led_ctrl_top.vcd");
        $dumpvars(0, tb_led_ctrl_top);

        errors = 0;
        key    = 1'b0;
        rst_n  = 1'b0;

        // ---- 复位 ----
        #(CLK_PERIOD * 20);
        rst_n = 1'b1;
        #(CLK_PERIOD * 20);

        $display("========================================");
        $display("  led_ctrl_top 仿真验证");
        $display("========================================");

        // ---- 检查1：复位后模式应为 0 ----
        $display("[检查1] 复位后模式");
        if (dut.mode !== 3'd0) begin
            $display("  [FAIL] 复位后 mode=%0d，期望 0", dut.mode);
            errors = errors + 1;
        end
        else begin
            $display("  [PASS] 复位后 mode=0");
        end

        // ---- 检查2：按键递增模式 ----
        $display("[检查2] 按键切换模式");
        for (i = 0; i < 4; i = i + 1) begin
            press_key;
            if (dut.mode !== (i + 1)) begin
                $display("  [FAIL] 第%0d次按键后 mode=%0d，期望 %0d",
                         i + 1, dut.mode, i + 1);
                errors = errors + 1;
            end
            else begin
                $display("  [PASS] 第%0d次按键后 mode=%0d", i + 1, dut.mode);
            end
        end

        // ---- 检查3：模式循环（模式4后再按应回到模式0）----
        $display("[检查3] 模式循环回绕");
        press_key;
        if (dut.mode !== 3'd0) begin
            $display("  [FAIL] 模式4后按键 mode=%0d，期望回到 0", dut.mode);
            errors = errors + 1;
        end
        else begin
            $display("  [PASS] 模式4后按键正确回到 mode=0");
        end

        // ---- 检查4：全灭模式（直接设置 mode=4）----
        $display("[检查4] 全灭模式输出");
        check_mode(3'd4, 6'b111111, "ALL-OFF");

        // ---- 检查5：跑马灯模式至少有一个 LED 点亮（低电平有效）----
        $display("[检查5] 跑马灯模式输出");
        force dut.pat_marquee = 6'b000001;
        check_mode(3'd3, 6'b111110, "MARQUEE");
        release dut.pat_marquee;

        // ---- 检查6：流水灯模式 ----
        $display("[检查6] 流水灯模式输出");
        force dut.pat_flow = 6'b000010;
        check_mode(3'd0, 6'b111101, "FLOW");
        release dut.pat_flow;

        // ---- 汇总 ----
        $display("========================================");
        if (errors == 0)
            $display("  全部通过：0 个错误");
        else
            $display("  验证失败：%0d 个错误", errors);
        $display("========================================");

        $finish;
    end

    // ---- 超时保护 ----
    initial begin
        #(CLK_PERIOD * 200000);
        $display("[ERROR] 仿真超时");
        $finish;
    end

endmodule
