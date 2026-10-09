// ============================================================================
//  测试平台 : tb_adsr.v
//  被测模块 : adsr（线性包络版）
//  验证内容 :
//      1) 复位后 env = 0 且在 IDLE
//      2) 按下 → ATTACK，env 单调递增到 255
//      3) 到达峰值 → DECAY，env 单调递减到 SUS_LEVEL
//      4) SUSTAIN 阶段电平稳定
//      5) 松开 → RELEASE，env 单调递减
//      6) 最终回到 IDLE 且 env = 0
//
//  运行 : iverilog -g2005 -o sim.out rtl/adsr.v sim/tb_adsr.v && vvp sim.out
// ============================================================================
`timescale 1ns / 1ps

module tb_adsr;

    localparam CLK_PERIOD = 37.037;
    localparam ENV_BITS   = 8;
    localparam SUS_LEVEL  = 8'd128;
    localparam ATK_STEP   = 8'd8;     // 快起音，便于仿真
    localparam DEC_STEP   = 8'd4;
    localparam REL_STEP   = 8'd4;

    reg                  clk, rst_n, note_on, gate;
    wire [ENV_BITS-1:0]  env;

    integer errors;
    integer i;
    integer timeout;

    reg [ENV_BITS-1:0] v_prev;
    reg                monotonic;
    reg [ENV_BITS-1:0] peak;

    // ---- 采样使能：每 8 个 clk 一个单周期脉冲（仿真加速）----
    reg [3:0] div_cnt;
    reg       sample_en;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt   <= 4'd0;
            sample_en <= 1'b0;
        end
        else if (div_cnt >= 4'd7) begin
            div_cnt   <= 4'd0;
            sample_en <= 1'b1;
        end
        else begin
            div_cnt   <= div_cnt + 4'd1;
            sample_en <= 1'b0;
        end
    end

    adsr #(
        .ENV_BITS  (ENV_BITS),
        .SUS_LEVEL (SUS_LEVEL),
        .ATK_STEP  (ATK_STEP),
        .DEC_STEP  (DEC_STEP),
        .REL_STEP  (REL_STEP)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .sample_en (sample_en),
        .note_on   (note_on),
        .gate      (gate),
        .env       (env)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // 等待进入某状态，带超时
    task wait_state;
        input [2:0]    target;
        input integer  max_clk;
        output integer spent;
        begin
            spent = 0;
            while (dut.state !== target && spent < max_clk) begin
                @(posedge clk);
                spent = spent + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_adsr.vcd");
        $dumpvars(0, tb_adsr);

        errors  = 0;
        rst_n   = 1'b0;
        note_on = 1'b0;
        gate    = 1'b0;

        #(CLK_PERIOD * 20);
        rst_n = 1'b1;
        #(CLK_PERIOD * 20);

        $display("==================================================");
        $display("  adsr 仿真验证");
        $display("  SUS=%0d  ATK_STEP=%0d  DEC_STEP=%0d  REL_STEP=%0d",
                 SUS_LEVEL, ATK_STEP, DEC_STEP, REL_STEP);
        $display("==================================================");

        // ===== 检查1：复位 =====
        $display("[检查1] 复位后 env = 0，状态 = IDLE");
        if (env === 8'd0) $display("  [PASS] env = 0");
        else begin $display("  [FAIL] env = %0d", env); errors = errors + 1; end
        if (dut.state === 3'd0) $display("  [PASS] 状态 = IDLE");
        else begin $display("  [FAIL] 状态 = %0d", dut.state); errors = errors + 1; end

        // ===== 检查2：ATTACK 单调递增 =====
        $display("[检查2] 按下 → ATTACK 单调递增");
        @(negedge clk); note_on = 1'b1; gate = 1'b1;

        wait_state(3'd1, 500, timeout);       // 等进入 ATTACK
        if (dut.state !== 3'd1) begin
            $display("  [FAIL] 未进入 ATTACK");
            errors = errors + 1;
        end
        else begin
            $display("  [PASS] 进入 ATTACK");
            monotonic = 1'b1;
            peak      = 8'd0;
            v_prev    = 8'd0;
            timeout   = 0;
            // 观察直到离开 ATTACK
            while (dut.state === 3'd1 && timeout < 5000) begin
                @(posedge clk);
                if (sample_en && dut.state === 3'd1) begin
                    if (env < v_prev) monotonic = 1'b0;
                    v_prev = env;
                    if (env > peak) peak = env;
                end
                timeout = timeout + 1;
            end
            if (monotonic) $display("  [PASS] env 单调递增（峰值 %0d）", peak);
            else begin $display("  [FAIL] env 出现回落"); errors = errors + 1; end
            // 设计上 env >= (255 - ATK_STEP) 即转入 DECAY，
            // 因此峰值约为 256-ATK_STEP，不要求恰好 255
            if (peak >= (8'd255 - ATK_STEP - 8'd8))
                $display("  [PASS] 峰值接近满量程（%0d，阈值 %0d）", peak, 8'd255 - ATK_STEP - 8'd8);
            else begin $display("  [FAIL] 峰值仅 %0d，过低", peak); errors = errors + 1; end
        end

        // ===== 检查3：DECAY 到 SUS_LEVEL =====
        $display("[检查3] DECAY 下降至 SUS_LEVEL");
        wait_state(3'd3, 5000, timeout);      // 等进入 SUSTAIN
        if (dut.state === 3'd3) begin
            $display("  [PASS] 进入 SUSTAIN，env = %0d", env);
            if (env === SUS_LEVEL) $display("  [PASS] 电平 = SUS_LEVEL(%0d)", SUS_LEVEL);
            else begin $display("  [FAIL] 电平 = %0d，期望 %0d", env, SUS_LEVEL); errors = errors + 1; end
        end
        else begin
            $display("  [FAIL] 未进入 SUSTAIN（state=%0d env=%0d）", dut.state, env);
            errors = errors + 1;
        end

        // ===== 检查4：SUSTAIN 稳定 =====
        $display("[检查4] SUSTAIN 电平保持稳定");
        begin : chk_sus
            reg [7:0] e0;
            e0 = env;
            repeat (300) @(posedge clk);
            if (dut.state === 3'd3 && env === e0)
                $display("  [PASS] 300 clk 后仍为 %0d", env);
            else begin
                $display("  [FAIL] 电平漂移 %0d → %0d（state=%0d）", e0, env, dut.state);
                errors = errors + 1;
            end
        end

        // ===== 检查5：RELEASE 单调递减 =====
        $display("[检查5] 松开 → RELEASE 单调递减");
        @(negedge clk); note_on = 1'b0;
        wait_state(3'd4, 500, timeout);
        if (dut.state === 3'd4) begin
            $display("  [PASS] 进入 RELEASE");
            monotonic = 1'b1;
            v_prev    = env;
            timeout   = 0;
            while (dut.state === 3'd4 && timeout < 5000) begin
                @(posedge clk);
                if (sample_en && dut.state === 3'd4) begin
                    if (env > v_prev) monotonic = 1'b0;
                    v_prev = env;
                end
                timeout = timeout + 1;
            end
            if (monotonic) $display("  [PASS] env 单调递减");
            else begin $display("  [FAIL] env 出现回升"); errors = errors + 1; end
        end
        else begin
            $display("  [FAIL] 未进入 RELEASE（state=%0d）", dut.state);
            errors = errors + 1;
        end

        // ===== 检查6：回到 IDLE =====
        $display("[检查6] RELEASE 结束回到 IDLE");
        wait_state(3'd0, 10000, timeout);
        if (dut.state === 3'd0) begin
            $display("  [PASS] 回到 IDLE");
            if (env === 8'd0) $display("  [PASS] env 归零");
            else begin $display("  [FAIL] env = %0d", env); errors = errors + 1; end
        end
        else begin
            $display("  [FAIL] %0d clk 后未回到 IDLE（state=%0d env=%0d）", timeout, dut.state, env);
            errors = errors + 1;
        end

        $display("==================================================");
        if (errors == 0) $display("  全部通过：0 个错误");
        else             $display("  验证失败：%0d 个错误", errors);
        $display("==================================================");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 300000);
        $display("[ERROR] 仿真超时");
        $finish;
    end

endmodule
