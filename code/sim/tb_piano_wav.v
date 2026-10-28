// ============================================================================
//  测试平台 : tb_piano_wav.v
//  被测模块 : piano_engine（钢琴音色）
//  目的     : 导出一段 2.0 秒的钢琴音频（C4 单音，1.5 s 后松键）供试听
//
//  ── 为什么把 sample_req 缩短到 48 clk ──────────────────────────────
//  上板时 sample_req 每 512 clk 一次（I2S 帧率 52734 Hz）。
//  仿真里没必要按真实时钟跑：piano_engine 的行为只取决于
//  "每个 sample_req 之间发生了什么"，与 sample_req 的绝对间隔无关。
//  所以这里用 48 clk（> 内部 28 clk 的串行计算时间），把 2 秒音频的
//  仿真时间从 5.4e7 clk 压到 5.1e6 clk，快 10 倍。
//  WAV 播放时按 52734 Hz 解释，音高与衰减速度都是对的。
//
//  输出 : piano_2s.txt（每行一个十进制样本，16 位有符号）
//  用法 : python tools/txt_to_wav.py  （转成 piano_2s.wav）
// ============================================================================
`timescale 1ns / 1ps

module tb_piano_wav;

    localparam CLK_PERIOD = 37.037;
    localparam VOICE_NUM  = 4;
    localparam SAMP_CLK   = 48;        // 每 48 clk 一个采样（内部需 28 clk）
    localparam N_SAMP     = 105469;    // 2.000 s @ 52734.375 Hz
    localparam RELEASE_AT = 79101;     // 1.500 s 处松键

    localparam [31:0] FCW_C4 = 32'd21308174;   // C4 261.63 Hz

    reg                    clk, rst_n;
    reg                    sample_req;
    reg  [VOICE_NUM*32-1:0] voice_fcw;
    reg  [VOICE_NUM-1:0]   voice_trig;
    reg  [VOICE_NUM-1:0]   voice_busy;
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

    // ---- 采样请求：每 SAMP_CLK 一个脉冲 ----
    integer samp_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            samp_cnt   <= 0;
            sample_req <= 1'b0;
        end
        else if (samp_cnt == SAMP_CLK - 1) begin
            samp_cnt   <= 0;
            sample_req <= 1'b1;
        end
        else begin
            samp_cnt   <= samp_cnt + 1;
            sample_req <= 1'b0;
        end
    end

    // ---- 在 sample_req 后第 30 拍取稳定输出（内部 28 拍算完）----
    reg [5:0] snag;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)             snag <= 6'd0;
        else if (sample_req)    snag <= 6'd0;
        else if (snag < 6'd40)  snag <= snag + 6'd1;
    end

    integer fd;
    integer idx;
    integer peak;
    integer i;

    always @(posedge clk) begin
        if (snag == 6'd30 && idx < N_SAMP) begin
            $fwrite(fd, "%0d\n", audio);
            if (audio > peak)  peak = audio;
            if (-audio > peak) peak = -audio;
            idx = idx + 1;
        end
    end

    initial begin
        fd         = $fopen("piano_2s.txt", "w");
        if (fd == 0) begin
            $display("[ERROR] cannot open piano_2s.txt");
            $finish;
        end

        idx        = 0;
        peak       = 0;
        rst_n      = 1'b0;
        sample_req = 1'b0;
        voice_fcw  = {(VOICE_NUM*32){1'b0}};
        voice_trig = {VOICE_NUM{1'b0}};
        voice_busy = {VOICE_NUM{1'b0}};

        repeat (200) @(posedge clk);
        rst_n = 1'b1;

        // ---- note-on：C4 ----
        @(negedge clk);
        voice_fcw[31:0] = FCW_C4;
        voice_trig[0]   = 1'b1;
        voice_busy[0]   = 1'b1;
        @(negedge clk);
        voice_trig[0]   = 1'b0;

        // ---- 1.5 s 后松键（damper 生效）----
        wait (idx >= RELEASE_AT);
        @(negedge clk);
        voice_busy[0] = 1'b0;

        // ---- 等导出 2.0 s ----
        wait (idx >= N_SAMP);
        repeat (10) @(posedge clk);
        $fclose(fd);

        $display("==================================================");
        $display("  piano_2s.txt written");
        $display("  samples = %0d  (%.3f s @ 52734 Hz)", idx, idx / 52734.375);
        $display("  peak    = %0d / 32767  (%.1f%%)", peak, peak * 100.0 / 32767.0);
        $display("==================================================");
        $finish;
    end

endmodule
