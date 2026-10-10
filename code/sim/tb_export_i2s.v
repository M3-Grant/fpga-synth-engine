// ============================================================================
//  测试平台 : tb_export_i2s.v
//  功能    : 导出真实 I2S 信号的时序数据，供 Proteus / 其他工具使用
//
//  ── 用途 ──────────────────────────────────────────────────────────
//  在板子到货前，把 Verilog 仿真产生的**真实 I2S 波形**导出：
//    · tb_export_i2s.vcd  → 用 GTKWave 看波形
//    · i2s_capture.csv    → 十六进制数据，可转成 Proteus 码型发生器文件
//
//  这样 Proteus 那边可以用「数字码型发生器」复现同样的 I2S 信号，
//  接到 DAC / 功放电路上，验证模拟部分 —— 不需要 Proteus 有 FPGA 模型。
//
//  ── 导出内容 ──────────────────────────────────────────────────────
//      BCK  : 位时钟
//      LRCK : 声道时钟
//      DIN  : 串行数据
//      MIX  : 混音输出（音频样本，用于核对）
//
//  作者    : 第二代迭代 04
// ============================================================================
`timescale 1ns / 1ps

module tb_export_i2s;

    localparam CLK_PERIOD = 37.037;    // 27MHz
    localparam VOICE_NUM  = 4;
    localparam NOTE_BITS  = 5;
    localparam EXPORT_CLKS = 300000;   // 导出多少主时钟周期（约 11ms 音频）

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

    // ---- 按下音符（等包络进入 SUSTAIN）----
    task press;
        input [NOTE_BITS-1:0] n;
        begin
            @(negedge clk); note_idx = n; note_on = 1'b1; note_valid = 1'b1;
            @(negedge clk); note_valid = 1'b0;
            repeat (30000) @(negedge clk);
        end
    endtask

    // ---- CSV 导出：记录每次 BCK 下降沿的信号状态 ----
    integer csv;
    integer n_rows;

    initial begin
        csv = $fopen("i2s_capture.csv", "w");
        if (csv == 0) begin
            $display("[ERROR] 无法创建 i2s_capture.csv");
            $finish;
        end
        $fwrite(csv, "# FPGA I2S capture - synth_top\n");
        $fwrite(csv, "# clk=27MHz, fs=52734.375Hz, BCK=3.375MHz\n");
        $fwrite(csv, "# 每行 = 一个 BCK 下降沿\n");
        $fwrite(csv, "index,bck,lrck,din,mix_signed\n");
        n_rows = 0;
    end

    // BCK 下降沿写一行
    reg bck_d;
    always @(posedge clk) begin
        bck_d <= i2s_bck;
        if (bck_d && !i2s_bck && n_rows < EXPORT_CLKS) begin
            $fwrite(csv, "%0d,%b,%b,%b,%0d\n",
                    n_rows, i2s_bck, i2s_lrck, i2s_din, $signed(dbg_mix));
            n_rows = n_rows + 1;
        end
    end

    initial begin
        $dumpfile("tb_export_i2s.vcd");
        $dumpvars(0, tb_export_i2s);

        rst_n      = 1'b0;
        note_valid = 1'b0;
        note_on    = 1'b0;
        note_idx   = 5'd0;
        bck_d      = 1'b0;

        #(CLK_PERIOD * 20);
        rst_n = 1'b1;
        #(CLK_PERIOD * 20);

        $display("==================================================");
        $display("  I2S 信号导出");
        $display("==================================================");

        // 弹一个 C 大三和弦（C4 + E4 + G4），展示复音
        $display("  按下 C4 (索引 0) ...");
        press(5'd0);
        $display("  按下 E4 (索引 4) ...");
        press(5'd4);
        $display("  按下 G4 (索引 7) ...");
        press(5'd7);

        // 再跑一段时间采集数据
        repeat (EXPORT_CLKS) @(negedge clk);

        $display("  已采集 %0d 行 BCK 数据", n_rows);
        $display("  声部状态: %b", dbg_voice_busy);
        $display("  最后混音值: %0d", $signed(dbg_mix));
        $fclose(csv);
        $display("  已导出: i2s_capture.csv");
        $display("  已导出: tb_export_i2s.vcd");
        $display("==================================================");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 3000000);
        $display("[超时]");
        $fclose(csv);
        $finish;
    end

endmodule
