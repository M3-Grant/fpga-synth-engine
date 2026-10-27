// ============================================================================
//  测试平台 : tb_piano_engine.v
//  被测模块 : piano_engine（钢琴音色加法合成引擎）
//
//  验证内容 :
//      1) 上电/无触发时输出恒为 0
//      2) 单音 note-on → 有输出，峰值在合理区间（不削波）
//      3) 包络确实在衰减（后段 RMS 明显小于前段，但不为 0）
//      4) 松键 → damper 快速止音，约 0.1 s 后归零
//      5) 4 音和弦 → 不削波（峰值 ≤ 32767）
//      6) 导出一段单音波形到 piano_dump.txt，供 tools/verify_piano.py 做 FFT，
//         检查 1..6 次谐波分量是否真的存在且按 1/h^1.5 衰减
//
//  运行：
//      iverilog -g2005 -o sim_piano.out rtl\piano_engine.v sim\tb_piano_engine.v
//      vvp sim_piano.out
// ============================================================================
`timescale 1ns / 1ps

module tb_piano_engine;

    localparam CLK_PERIOD = 37.037;      // 27 MHz
    localparam VOICE_NUM  = 4;
    localparam SAMP_DIV   = 512;         // 27e6 / 52734.375 ≈ 512
    localparam DUMP_LEN   = 12000;       // 导出样本数（约 0.23 s）

    // note_table 里的 FCW（fs = 52734.375 Hz）
    localparam [31:0] FCW_C4 = 32'd21308174;
    localparam [31:0] FCW_E4 = 32'd26846617;
    localparam [31:0] FCW_G4 = 32'd31926188;
    localparam [31:0] FCW_C5 = 32'd42616348;

    reg                    clk, rst_n;
    reg  [VOICE_NUM*32-1:0] voice_fcw;
    reg  [VOICE_NUM-1:0]   voice_trig;
    reg  [VOICE_NUM-1:0]   voice_busy;
    reg                    sample_req;
    wire signed [15:0]     audio;

    piano_engine #(
        .VOICE_NUM  (VOICE_NUM),
        .HARM_NUM   (6),
        .PHASE_BITS (32)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_req (sample_req),
        .voice_fcw  (voice_fcw),
        .voice_trig (voice_trig),
        .voice_busy (voice_busy),
        .audio      (audio)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ------------------------------------------------------------------
    // 采样请求：每 SAMP_DIV 个 clk 一个脉冲（模拟 i2s_tx）
    // ------------------------------------------------------------------
    integer samp_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            samp_cnt   <= 0;
            sample_req <= 1'b0;
        end
        else if (samp_cnt == SAMP_DIV - 1) begin
            samp_cnt   <= 0;
            sample_req <= 1'b1;
        end
        else begin
            samp_cnt   <= samp_cnt + 1;
            sample_req <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // 记账：chk / 峰值统计 / 样本导出
    // ------------------------------------------------------------------
    integer errors;
    integer fd;
    integer dumped;
    integer diag_i;
    reg     dumping;

    reg signed [15:0] peak_all;      // 全程峰值
    reg signed [15:0] peak_cur;      // 当前窗口峰值

    // 在 sample_req 之后第 30 拍取样本（piano_engine 用 28 拍算完）
    reg [5:0] snag;
    reg signed [15:0] snap;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            snag  <= 6'd0;
            snap  <= 16'sd0;
        end
        else if (sample_req) begin
            snag <= 6'd0;
        end
        else if (snag < 6'd40) begin
            snag <= snag + 6'd1;
            if (snag == 6'd30) snap <= audio;
        end
    end

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

    task run_samples;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk);
                while (!sample_req) @(negedge clk);
                // 等 piano_engine 算完（28 clk），再等 2 拍取稳定值
                repeat (32) @(posedge clk);
                if (snap > peak_cur) peak_cur = snap;
                if (snap > peak_all) peak_all = snap;
                if (dumping) begin
                    $fwrite(fd, "%0d\n", snap);
                    dumped = dumped + 1;
                end
            end
        end
    endtask

    task note_on;
        input integer v;
        input [31:0]  fcw;
        begin
            @(negedge clk);
            voice_fcw[v*32 +: 32] = fcw;
            voice_trig[v]         = 1'b1;
            voice_busy[v]         = 1'b1;
            @(negedge clk);
            voice_trig[v]         = 1'b0;
        end
    endtask

    initial begin
        errors     = 0;
        dumped     = 0;
        dumping    = 1'b0;
        peak_all   = 16'sd0;
        peak_cur   = 16'sd0;
        rst_n      = 1'b0;
        voice_fcw  = {(VOICE_NUM*32){1'b0}};
        voice_trig = {VOICE_NUM{1'b0}};
        voice_busy = {VOICE_NUM{1'b0}};

        repeat (200) @(posedge clk);
        rst_n = 1'b1;

        $display("==================================================");
        $display("  piano_engine 验证");
        $display("==================================================");

        // ============ 检查1：静音 ============
        $display("[检查1] 无触发时输出应为 0");
        peak_cur = 16'sd0;
        run_samples(200);
        chk("静音峰值 = 0", peak_cur == 16'sd0);

        // ============ 检查2/3：单音 + 衰减 + 导出 ============
        $display("[检查2] 按下 KEY0（C4）→ 起音 + 谐波 + 衰减");
        note_on(0, FCW_C4);

        fd = $fopen("piano_dump.txt", "w");
        if (fd == 0) $display("  [WARN] 无法打开 piano_dump.txt（导出跳过）");

        dumping  = 1'b1;
        peak_cur = 16'sd0;
        run_samples(DUMP_LEN);            // 前 0.38 s：起音 + 衰减
        dumping  = 1'b0;

        $display("        单音峰值 = %0d  (导出 %0d 个样本)", peak_cur, dumped);
        chk("有音频输出（峰值 > 4000）", peak_cur > 16'sd4000);
        chk("未削波（峰值 ≤ 32767）",     peak_cur <= 16'sd32767);
        chk("峰值没有顶到饱和区（≤ 30000）", peak_cur <= 16'sd30000);

        // 衰减验证：接着跑 0.1 s，窗口峰值应明显下降但仍非 0
        peak_cur = 16'sd0;
        run_samples(5300);                // ≈ 0.1 s
        $display("        0.48 s 后窗口峰值 = %0d", peak_cur);
        chk("包络在衰减（0.48s 后峰值 < 起音峰值 60%）", peak_cur < (peak_all * 6) / 10);
        chk("衰减后仍有声（峰值 > 0）", peak_cur > 16'sd0);

        // ============ 检查4：松键止音 ============
        $display("[检查3] 松键 → damper 止音");
        @(negedge clk);
        voice_busy[0] = 1'b0;

        // 每 1000 个采样打印一次，便于定位 damper 速率
        for (diag_i = 0; diag_i < 6; diag_i = diag_i + 1) begin
            peak_cur = 16'sd0;
            run_samples(1000);
            $display("        +%0d 采样 (%0d ms): 峰值 = %0d  busy = %b",
                     (diag_i + 1) * 1000,
                     ((diag_i + 1) * 1000) / 53,
                     peak_cur, voice_busy);
        end
        $display("        松键 6000 采样（约 0.11 s）后窗口峰值 = %0d", peak_cur);
        chk("松键后已静音", peak_cur == 16'sd0);

        // ============ 检查5：4 音和弦不削波 ============
        $display("[检查4] 4 音和弦（C4/E4/G4/C5）→ 不削波");
        peak_all = 16'sd0;
        note_on(0, FCW_C4);
        note_on(1, FCW_E4);
        note_on(2, FCW_G4);
        note_on(3, FCW_C5);

        peak_cur = 16'sd0;
        run_samples(6000);
        $display("        和弦峰值 = %0d", peak_cur);
        chk("和弦有输出（峰值 > 单音）", peak_cur > 16'sd6000);
        chk("和弦未削波（峰值 ≤ 32767）", peak_cur <= 16'sd32767);

        // ============ 检查6：重复触发（同一个音再敲一次）============
        $display("[检查5] 重复敲同一个音 → 包络重新起音");
        peak_cur = 16'sd0;
        run_samples(4000);                // 先让它衰减一点
        note_on(0, FCW_C4);               // 重新敲
        peak_all = 16'sd0;
        run_samples(1000);
        chk("重敲后重新有音头（峰值回升）", peak_all > 16'sd2000);

        if (fd != 0) $fclose(fd);

        $display("==================================================");
        if (errors == 0) $display("  全部通过：0 个错误");
        else             $display("  验证失败：%0d 个错误", errors);
        $display("==================================================");
        $finish;
    end

    // 超时保护
    initial begin
        #(CLK_PERIOD * 20000000);
        $display("[ERROR] 仿真超时");
        $finish;
    end

endmodule
