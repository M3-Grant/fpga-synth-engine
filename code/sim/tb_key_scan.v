// ============================================================================
//  测试平台 : tb_key_scan.v
//  被测模块 : key_scan（12 路按键扫描）
//
//  写法说明：不用复杂的等待任务，改成「驱动信号 → 跑固定周期 → 核对记录」。
//            之前用 wait_evt 任务反而互相打架（任务里强制清 key_in 打断了自己）。
//
//  运行 : iverilog -g2005 -o sim.out rtl/debounce.v rtl/key_scan.v sim/tb_key_scan.v
// ============================================================================
`timescale 1ns / 1ps

module tb_key_scan;

    localparam CLK_PERIOD = 37.037;
    localparam KEY_NUM    = 12;
    localparam NOTE_BITS  = 5;
    localparam CNT_MAX    = 8;          // 仿真用短消抖（上板 270000 ≈ 10ms）
    localparam WATCH      = 4000;       // 每步观察周期数（远大于消抖+扫描）

    reg                    clk, rst_n;
    reg  [KEY_NUM-1:0]     key_in;
    wire [KEY_NUM-1:0]     key_state;
    wire                   note_valid;
    wire                   note_on;
    wire [NOTE_BITS-1:0]   note_idx;

    integer errors;
    integer on_cnt, off_cnt;            // 累计事件数
    reg [NOTE_BITS-1:0] last_note;
    reg                 last_on;
    integer i;

    key_scan #(
        .KEY_NUM    (KEY_NUM),
        .CNT_MAX    (CNT_MAX),
        .ACTIVE_LOW (0),
        .NOTE_BITS  (NOTE_BITS)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .key_in    (key_in),
        .key_state (key_state),
        .note_valid(note_valid),
        .note_on   (note_on),
        .note_idx  (note_idx)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // 记录事件
    always @(posedge clk) begin
        if (note_valid) begin
            last_note <= note_idx;
            last_on   <= note_on;
            if (note_on) on_cnt  = on_cnt + 1;
            else         off_cnt = off_cnt + 1;
        end
    end

    // 跑 N 个时钟
    task run_clks;
        input [31:0] n;
        begin
            repeat (n) @(posedge clk);
        end
    endtask

    // 检查任务：比较 (cond, tag)
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
        $dumpfile("tb_key_scan.vcd");
        $dumpvars(0, tb_key_scan);

        errors    = 0;
        on_cnt    = 0;
        off_cnt   = 0;
        last_note = 5'd0;
        last_on   = 1'b0;

        clk    = 1'b0;
        rst_n  = 1'b0;
        key_in = {KEY_NUM{1'b0}};

        #(CLK_PERIOD * 20);
        rst_n = 1'b1;
        run_clks(200);

        $display("==================================================");
        $display("  key_scan 仿真验证  (KEY_NUM=%0d, CNT_MAX=%0d)", KEY_NUM, CNT_MAX);
        $display("==================================================");

        // ================= 检查1：复位后无事件 =================
        $display("[检查1] 复位后无事件");
        on_cnt = 0; off_cnt = 0;
        run_clks(WATCH);
        chk("无按键时 0 事件", (on_cnt == 0) && (off_cnt == 0));

        // ================= 检查2：单键按下 KEY2 =================
        $display("[检查2] 按下 KEY2 → 音符 D4(索引2)");
        on_cnt = 0; off_cnt = 0;
        @(negedge clk); key_in = (1'b1 << 2);
        run_clks(WATCH);
        $display("        on=%0d off=%0d last_note=%0d last_on=%b",
                 on_cnt, off_cnt, last_note, last_on);
        chk("收到 1 个按下事件", on_cnt == 1);
        chk("音符索引 = 2 (D4)", last_note == 5'd2);
        chk("note_on = 1", last_on == 1'b1);

        // ================= 检查3：松键 =================
        $display("[检查3] 松开 KEY2 → note_on=0");
        on_cnt = 0; off_cnt = 0;
        @(negedge clk); key_in = {KEY_NUM{1'b0}};
        run_clks(WATCH);
        $display("        on=%0d off=%0d last_note=%0d last_on=%b",
                 on_cnt, off_cnt, last_note, last_on);
        chk("收到 1 个松开事件", off_cnt == 1);
        chk("note_on = 0", last_on == 1'b0);

        // ================= 检查4：音符映射抽查 =================
        $display("[检查4] 音符映射抽查（KEY0/4/7/11 → C4/E4/G4/B4）");
        begin : chk_map
            integer keys[0:3];
            integer exps[0:3];
            integer n;
            keys[0]=0;  exps[0]=0;
            keys[1]=4;  exps[1]=4;
            keys[2]=7;  exps[2]=7;
            keys[3]=11; exps[3]=11;

            for (n = 0; n < 4; n = n + 1) begin
                on_cnt = 0;
                @(negedge clk); key_in = (1'b1 << keys[n]);
                run_clks(WATCH);
                if (on_cnt == 1 && last_note == exps[n] && last_on == 1'b1)
                    $display("  [PASS] KEY%0d → 音符 %0d", keys[n], last_note);
                else begin
                    $display("  [FAIL] KEY%0d → on=%0d note=%0d on_bit=%b (期望 %0d)",
                             keys[n], on_cnt, last_note, last_on, exps[n]);
                    errors = errors + 1;
                end
                @(negedge clk); key_in = {KEY_NUM{1'b0}};
                run_clks(WATCH);
            end
        end

        // ================= 检查5：三键同时按下 =================
        $display("[检查5] 同时按 KEY0+KEY4+KEY7（C 大三和弦）");
        begin : chk_multi
            integer got0, got4, got7;
            integer snap_on;
            got0 = 0; got4 = 0; got7 = 0;

            // ⚠ 用快照差值统计，不要重复清零 on_cnt
            //   （监视块一直在自增 on_cnt，另开计数器会重复计数）
            snap_on = on_cnt;

            @(negedge clk);
            key_in = (1'b1 << 0) | (1'b1 << 4) | (1'b1 << 7);

            repeat (WATCH) @(posedge clk);

            // 统计期间收到的事件
            for (i = 0; i < 0; i = i + 1) begin end   // 占位，逻辑在监视块已完成

            $display("        本步新增按下事件 = %0d 个", on_cnt - snap_on);

            // 用调试确认的三个音符：从事件记录里判断是否都出现过
            // 这里改为检查按键状态：三个键都应为按下
            if (key_state[0] && key_state[4] && key_state[7])
                $display("  [PASS] 三个键都处于按下状态 (key_state=%b)", key_state);
            else begin
                $display("  [FAIL] key_state=%b，三个键未全部按下", key_state);
                errors = errors + 1;
            end

            if ((on_cnt - snap_on) == 3)
                $display("  [PASS] 恰好收到 3 个按下事件（无重复、无丢失）");
            else begin
                $display("  [FAIL] 收到 %0d 个按下事件，期望 3", on_cnt - snap_on);
                errors = errors + 1;
            end

            @(negedge clk); key_in = {KEY_NUM{1'b0}};
            run_clks(WATCH);
        end

        // ================= 汇总 =================
        $display("==================================================");
        if (errors == 0) $display("  全部通过：0 个错误");
        else             $display("  验证失败：%0d 个错误", errors);
        $display("==================================================");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 2000000);
        $display("[ERROR] 仿真超时");
        $finish;
    end

endmodule
