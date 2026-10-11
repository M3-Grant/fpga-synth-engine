// ============================================================================
//  测试平台 : tb_export_wav.v
//  功能    : 把复音合成器的输出导出为 WAV 音频文件，可直接用播放器试听
//
//  ── 为什么做这个 ──────────────────────────────────────────────────
//  板子还没到货，但代码逻辑已经验证过了。把仿真输出写成标准 WAV，
//  用任何播放器就能听到真实效果 —— 没有硬件时最直接的判断方式。
//
//  ── WAV 格式要点 ──────────────────────────────────────────────────
//  16 位单声道 PCM，采样率 = 52734 Hz（不是 48000！见 gen_fcw.py）
//  数据是小端字节序（低字节在前），这是最容易写错的地方。
//
//  ── 实现说明 ──────────────────────────────────────────────────────
//  时间控制用「按采样数计数」而不是 repeat 长表达式，
//  因为 iverilog 对 `repeat (n * 512)` 这类写法支持不佳。
//
//  作者    : 第二代迭代 04
// ============================================================================
`timescale 1ns / 1ps

module tb_export_wav;

    localparam CLK_PERIOD = 37.037;      // 27MHz
    localparam VOICE_NUM  = 4;
    localparam NOTE_BITS  = 5;
    localparam FS         = 52734.375;   // 实际采样率

    reg                    clk, rst_n;
    reg                    note_valid, note_on;
    reg  [NOTE_BITS-1:0]   note_idx;
    wire                   i2s_bck, i2s_lrck, i2s_din;
    wire [VOICE_NUM-1:0]   dbg_voice_busy;
    wire signed [15:0]     dbg_mix;

    synth_top #(
        .VOICE_NUM (VOICE_NUM),
        .NOTE_BITS (NOTE_BITS)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .note_valid     (note_valid),
        .note_on        (note_on),
        .note_idx       (note_idx),
        .i2s_bck        (i2s_bck),
        .i2s_lrck       (i2s_lrck),
        .i2s_din        (i2s_din),
        .dbg_voice_busy (dbg_voice_busy),
        .dbg_mix        (dbg_mix)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ------------------------------------------------------------------
    // 采样计数器：全局节拍。每 512 个 clk 计一次（= 一个音频采样）
    // ------------------------------------------------------------------
    integer sample_tick;      // 已过去的采样数
    integer clk_cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            clk_cnt     <= 0;
            sample_tick <= 0;
        end
        else begin
            if (clk_cnt >= 511) begin
                clk_cnt     <= 0;
                sample_tick <= sample_tick + 1;
            end
            else begin
                clk_cnt <= clk_cnt + 1;
            end
        end
    end

    // ------------------------------------------------------------------
    // 导出样本（十六进制文本，每行一个 16 位样本）
    //
    // ⚠ 为什么不用 $fwrite("%c") 写二进制：
    //   iverilog 的 %c 会把 NUL 字节(0x00)当字符串终止符，
    //   而音频样本的低字节经常是 0x00，导致数据在第一个 0x00 处截断。
    //   现象：WAV 文件头正常，但数据几乎为空，播放器显示时长 0、
    //         只能听到极短的一段 —— 这个坑实际踩到过。
    //   改用十六进制文本，完全避开二进制写入问题。
    //
    // 每行格式：XXXX（4 位十六进制，16 位有符号样本的补码）
    //   例如 F800 = -2048，0800 = +2048
    // ------------------------------------------------------------------
    integer wav;
    integer n_samples;
    integer t0;                // 时间锚点（模块级，Verilog-2001 不允许在 initial 内声明）

    reg req_d;

    always @(posedge clk) begin
        req_d <= dut.sample_req;
        if (dut.sample_req && !req_d) begin
            $fwrite(wav, "%02x%02x\n", dbg_mix[15:8], dbg_mix[7:0]);
            n_samples = n_samples + 1;
        end
    end

    // ------------------------------------------------------------------
    initial begin
        // $dumpfile 关闭以提速
        // $dumpvars 关闭

        rst_n      = 1'b0;
        note_valid = 1'b0;
        note_on    = 1'b0;
        note_idx   = 5'd0;
        req_d      = 1'b0;
        n_samples  = 0;

        wav = $fopen("synth_demo.hex", "w");
        if (wav == 0) begin
            $display("[ERROR] 无法创建 synth_demo.hex");
            $finish;
        end

        #(CLK_PERIOD * 20);
        rst_n = 1'b1;
        #(CLK_PERIOD * 20);

        $display("==================================================");
        $display("  WAV 导出 —— 复音合成器演奏");
        $display("  采样率 = %0.1f Hz，16bit 单声道", FS);
        $display("==================================================");

        // ============ 1. 单音 C4：起音 + 保持 + 余韵 ============
        $display("  [1] 单音 C4");
        @(negedge clk); note_idx = 5'd0; note_on = 1; note_valid = 1;
        @(negedge clk); note_valid = 0;
        t0 = sample_tick + 30000;
        while (sample_tick < t0) @(negedge clk);
        @(negedge clk); note_idx = 5'd0; note_on = 0; note_valid = 1;
        @(negedge clk); note_valid = 0;
        t0 = sample_tick + 8000;
        while (sample_tick < t0) @(negedge clk);

        // ============ 2. C 大三和弦齐奏 ============
        $display("  [2] C 大三和弦（C4 + E4 + G4）");
        @(negedge clk); note_idx = 5'd0; note_on = 1; note_valid = 1;
        @(negedge clk); note_valid = 0;
        @(negedge clk); note_idx = 5'd4; note_on = 1; note_valid = 1;
        @(negedge clk); note_valid = 0;
        @(negedge clk); note_idx = 5'd7; note_on = 1; note_valid = 1;
        @(negedge clk); note_valid = 0;
        t0 = sample_tick + 35000;
        while (sample_tick < t0) @(negedge clk);

        @(negedge clk); note_idx = 5'd0; note_on = 0; note_valid = 1;
        @(negedge clk); note_valid = 0;
        @(negedge clk); note_idx = 5'd4; note_on = 0; note_valid = 1;
        @(negedge clk); note_valid = 0;
        @(negedge clk); note_idx = 5'd7; note_on = 0; note_valid = 1;
        @(negedge clk); note_valid = 0;
        t0 = sample_tick + 11000;
        while (sample_tick < t0) @(negedge clk);

        // ============ 3. 琶音 ============
        $display("  [3] 琶音 C-E-G-C");
        @(negedge clk); note_idx = 5'd0; note_on = 1; note_valid = 1;
        @(negedge clk); note_valid = 0;
        t0 = sample_tick + 11000;  while (sample_tick < t0) @(negedge clk);
        @(negedge clk); note_idx = 5'd0; note_on = 0; note_valid = 1;
        @(negedge clk); note_valid = 0;

        @(negedge clk); note_idx = 5'd4; note_on = 1; note_valid = 1;
        @(negedge clk); note_valid = 0;
        t0 = sample_tick + 11000;  while (sample_tick < t0) @(negedge clk);
        @(negedge clk); note_idx = 5'd4; note_on = 0; note_valid = 1;
        @(negedge clk); note_valid = 0;

        @(negedge clk); note_idx = 5'd7; note_on = 1; note_valid = 1;
        @(negedge clk); note_valid = 0;
        t0 = sample_tick + 11000;  while (sample_tick < t0) @(negedge clk);
        @(negedge clk); note_idx = 5'd7; note_on = 0; note_valid = 1;
        @(negedge clk); note_valid = 0;

        @(negedge clk); note_idx = 5'd12; note_on = 1; note_valid = 1;
        @(negedge clk); note_valid = 0;
        t0 = sample_tick + 11000;  while (sample_tick < t0) @(negedge clk);
        @(negedge clk); note_idx = 5'd12; note_on = 0; note_valid = 1;
        @(negedge clk); note_valid = 0;
        t0 = sample_tick + 8000;  while (sample_tick < t0) @(negedge clk);

        // ============ 4. 四音叠加 ============
        $display("  [4] 四音叠加 C4+E4+G4+C5");
        @(negedge clk); note_idx = 5'd0;  note_on = 1; note_valid = 1;
        @(negedge clk); note_valid = 0;
        @(negedge clk); note_idx = 5'd4;  note_on = 1; note_valid = 1;
        @(negedge clk); note_valid = 0;
        @(negedge clk); note_idx = 5'd7;  note_on = 1; note_valid = 1;
        @(negedge clk); note_valid = 0;
        @(negedge clk); note_idx = 5'd12; note_on = 1; note_valid = 1;
        @(negedge clk); note_valid = 0;
        t0 = sample_tick + 35000;
        while (sample_tick < t0) @(negedge clk);

        @(negedge clk); note_idx = 5'd0;  note_on = 0; note_valid = 1;
        @(negedge clk); note_valid = 0;
        @(negedge clk); note_idx = 5'd4;  note_on = 0; note_valid = 1;
        @(negedge clk); note_valid = 0;
        @(negedge clk); note_idx = 5'd7;  note_on = 0; note_valid = 1;
        @(negedge clk); note_valid = 0;
        @(negedge clk); note_idx = 5'd12; note_on = 0; note_valid = 1;
        @(negedge clk); note_valid = 0;
        t0 = sample_tick + 11000;
        while (sample_tick < t0) @(negedge clk);

        $fclose(wav);
        $display("==================================================");
        $display("  已导出 %0d 个采样", n_samples);
        $display("  时长 ≈ %0.2f 秒", n_samples / FS);
        $display("  文件: synth_demo.hex（十六进制文本）");
        $display("==================================================");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 200000000);
        $display("[超时]");
        $finish;
    end

endmodule
