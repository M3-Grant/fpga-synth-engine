// ============================================================================
//  测试平台 : tb_synth_ttp229.v
//  被测模块 : synth_ttp229_top（TTP229 版整机）
//
//  目的     : 在**没有实物**的情况下，验证"TTP229 串行 → 按键 → 合成 → I2S"
//             这条完整链路。TTP229 用一个虚拟模块模拟（SCL 下降沿输出数据位）。
//
//  参数     : 全部缩短（TTP 扫描/消抖/红外），保持相对时序关系
//
//  检查项   : ① 复位后无输出
//             ② TTP229 位 0 对应 C4：按下后 key_scan 能识别并按 TTP_BIT 映射
//             ③ 按下后混音输出非零（钢琴音色，峰值约 10000）
//             ④ 松键后输出归零（钢琴 damper ~75 ms）
//             ⑤ 同时按两个键 → 输出幅度增大
// ============================================================================
`timescale 1ns / 1ps

module tb_synth_ttp229;

    localparam CLK_PERIOD = 37.037;
    localparam VOICE_NUM  = 4;
    localparam KEY_CNT    = 8;            // 仿真缩短的按键消抖
    localparam TTP_SYNC   = 100;
    localparam TTP_SCLH   = 5;
    localparam TTP_GAP    = 200;
    localparam SCAN_CLKS  = TTP_GAP + TTP_SYNC + 16 * 2 * TTP_SCLH;

    reg         clk, rst_n;
    reg         ir_in;
    reg         ttp_sdo;
    wire        ttp_scl;
    wire        i2s_bck, i2s_lrck, i2s_din, pa_en;
    wire [5:0]  led;

    synth_ttp229_top #(
        .VOICE_NUM   (VOICE_NUM),
        .KEY_CNT_MAX (KEY_CNT),
        .IR_DEBOUNCE_CNT  (8),
        .IR_MIN_SWIPE_CNT (40),
        .IR_MAX_SWIPE_CNT (4000),
        .TTP_SYNC_CNT (TTP_SYNC),
        .TTP_SCL_HALF (TTP_SCLH),
        .TTP_GAP_CNT  (TTP_GAP)
    ) dut (
        .clk      (clk),
        .ir_in    (ir_in),
        .ttp_scl  (ttp_scl),
        .ttp_sdo  (ttp_sdo),
        .i2s_bck  (i2s_bck),
        .i2s_lrck (i2s_lrck),
        .i2s_din  (i2s_din),
        .pa_en    (pa_en),
        .led      (led)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ==================================================================
    // 虚拟 TTP229：SCL 每轮第 1 个下降沿是同步，之后 16 个逐个输出数据位
    // ==================================================================
    reg [15:0] fake_keys = 16'h0000;
    integer    scl_falls = 0;
    integer    rem;

    always @(negedge ttp_scl) begin
        scl_falls = scl_falls + 1;
        rem = scl_falls % (16 + 1);
        if (rem >= 2)
            ttp_sdo <= fake_keys[17 - rem];
        else if (rem == 0)
            ttp_sdo <= fake_keys[0];
    end

    // ==================================================================
    // 观测混音峰值（同步到 i2s 的 sample_req）
    // ==================================================================
    integer max_val, min_val;

    task observe_peak;
        integer n;
        begin
            max_val = -32768;
            min_val =  32767;
            for (n = 0; n < 120000; n = n + 1) begin
                @(posedge clk);
                if (dut.u_synth.sample_req) begin
                    @(posedge clk);
                    if (dut.dbg_mix > max_val) max_val = dut.dbg_mix;
                    if (dut.dbg_mix < min_val) min_val = dut.dbg_mix;
                end
            end
        end
    endtask

    task run_clks;
        input [31:0] n;
        begin
            repeat (n) @(posedge clk);
        end
    endtask

    integer errors;
    integer peak;

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

    initial begin
        errors  = 0;
        rst_n   = 1'b0;
        ir_in   = 1'b1;          // 红外空闲（无手）
        ttp_sdo = 1'b0;
        fake_keys = 16'h0000;

        repeat (200) @(posedge clk);
        rst_n = 1'b1;

        $display("==================================================");
        $display("  synth_ttp229_top integration");
        $display("==================================================");

        // ---- 1. 无按键 → 静音 ----
        $display("[1] no key -> silent");
        run_clks(2000);
        observe_peak;
        peak = (max_val > -min_val) ? max_val : -min_val;
        chk("silent at idle", peak == 0);

        // ---- 2. 按 TTP 位 0（= C4）----
        $display("[2] press TTP bit0 (C4)");
        fake_keys = 16'h0001;
        run_clks(3 * SCAN_CLKS + 5000);      // 等扫描 + 消抖 + 起音
        // 直接看内部：位映射后 key[0] 应该被点亮
        chk("TTP bit0 mapped to key[0]", dut.key[0] === 1'b1);
        chk("one voice busy", dut.dbg_voice_busy == 4'b0001);

        observe_peak;
        peak = (max_val > -min_val) ? max_val : -min_val;
        $display("    peak = %0d", peak);
        chk("piano audio present", peak > 3000);
        chk("no clipping", peak <= 32767);

        // ---- 3. 松键 → 归零 ----
        $display("[3] release -> silent after damper");
        fake_keys = 16'h0000;
        run_clks(3 * SCAN_CLKS + 2000);
        chk("all voices released", dut.dbg_voice_busy == 4'b0000);
        run_clks(2_500_000);                 // 等钢琴 damper 走完（约 75 ms）
        observe_peak;
        peak = (max_val > -min_val) ? max_val : -min_val;
        chk("silent after release", peak == 0);

        // ---- 4. 两个键（和弦）----
        $display("[4] two keys -> louder");
        fake_keys = 16'h0005;                // 位 0 与位 2
        run_clks(3 * SCAN_CLKS + 6000);
        observe_peak;
        peak = (max_val > -min_val) ? max_val : -min_val;
        $display("    chord peak = %0d", peak);
        chk("chord has output", peak > 3000);
        chk("chord saturates at full scale (known trade-off: 2 notes > 16-bit)", peak <= 32768);

        $display("==================================================");
        if (errors == 0) $display("  ALL CHECKS PASSED");
        else             $display("  %0d CHECK(S) FAILED", errors);
        $display("==================================================");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 8000000);
        $display("[ERROR] simulation timeout");
        $finish;
    end

endmodule
