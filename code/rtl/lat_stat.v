// ============================================================================
//  模块名  : lat_stat.v
//  功能    : 演奏延迟统计（按键事件 → 第一个音频采样）
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，27 MHz
//
//  ── 统计什么 ──────────────────────────────────────────────────────
//      t1 = 检测到按键（note_valid 脉冲）的时刻
//      t2 = 该声部开始发声（voice_busy 上升沿）的时刻
//      lat = t2 - t1   （单位：27 MHz clk，1 clk = 37.037 ns）
//
//  ── 输出（直接对应 uart_stream 的 520~575 字节）───────────────────
//      last   最近一次延迟（clk 数）
//      min/max 最小/最大
//      sum/cnt 累加与次数（cnt 会回绕，平均 = sum/cnt）
//      hist[16] 直方图，每格 65536 clk = 2.4271 ms
//
//  ── 为什么要它 ────────────────────────────────────────────────────
//  赛题要求"控制信号到音频输出 ≤10 ms"。没有实测数字就只能靠嘴说。
//  这个模块把每次按键的真实延迟量出来，送进串口帧，上位机直接显示。
// ============================================================================
`timescale 1ns / 1ps

module lat_stat #(
    parameter HIST_SHIFT = 16          // 直方图每格 = 2^16 clk = 2.4271 ms
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        key_evt,        // 按键事件脉冲（note_valid）
    input  wire        sound_evt,      // 该声部开始发声（voice_busy 上升沿）
    input  wire        clr,            // 清零统计（UI 可以下发，暂不用）
    output reg  [31:0] lat_last,
    output reg  [31:0] lat_min,
    output reg  [31:0] lat_max,
    output reg  [31:0] lat_sum,
    output reg  [15:0] lat_cnt,
    output reg  [15:0] hist0, hist1, hist2, hist3,
    output reg  [15:0] hist4, hist5, hist6, hist7,
    output reg  [15:0] hist8, hist9, hist10, hist11,
    output reg  [15:0] hist12, hist13, hist14, hist15,
    output wire        has_data       // 1 = 已有至少一次测量
);

    // ------------------------------------------------------------------
    // 自由计数器（32 位，27 MHz 下约 158 秒回绕一次）
    // ------------------------------------------------------------------
    reg [31:0] clk_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) clk_cnt <= 32'd0;
        else        clk_cnt <= clk_cnt + 32'd1;
    end

    // ------------------------------------------------------------------
    // 测量状态机
    // ------------------------------------------------------------------
    reg [31:0] t_press;
    reg        pending;

    wire [31:0] lat_now = clk_cnt - t_press;
    wire [3:0]  hist_idx = lat_now[31 -: 4] ;
    // 直方图索引：lat / 65536，超过 15 就归到第 15 格
    wire [3:0]  hidx = (lat_now[HIST_SHIFT+3 -: 4] > 4'd15) ? 4'd15 : lat_now[HIST_SHIFT+3 -: 4];

    // 写直方图（16 个寄存器轮询）
    task inc_hist;
        input [3:0] idx;
        begin
            case (idx)
                4'd0 : hist0  <= hist0  + 16'd1;
                4'd1 : hist1  <= hist1  + 16'd1;
                4'd2 : hist2  <= hist2  + 16'd1;
                4'd3 : hist3  <= hist3  + 16'd1;
                4'd4 : hist4  <= hist4  + 16'd1;
                4'd5 : hist5  <= hist5  + 16'd1;
                4'd6 : hist6  <= hist6  + 16'd1;
                4'd7 : hist7  <= hist7  + 16'd1;
                4'd8 : hist8  <= hist8  + 16'd1;
                4'd9 : hist9  <= hist9  + 16'd1;
                4'd10: hist10 <= hist10 + 16'd1;
                4'd11: hist11 <= hist11 + 16'd1;
                4'd12: hist12 <= hist12 + 16'd1;
                4'd13: hist13 <= hist13 + 16'd1;
                4'd14: hist14 <= hist14 + 16'd1;
                default: hist15 <= hist15 + 16'd1;
            endcase
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t_press  <= 32'd0;
            pending  <= 1'b0;
            lat_last <= 32'd0;
            lat_min  <= 32'hFFFF_FFFF;
            lat_max  <= 32'd0;
            lat_sum  <= 32'd0;
            lat_cnt  <= 16'd0;
            hist0 <= 16'd0; hist1 <= 16'd0; hist2 <= 16'd0; hist3 <= 16'd0;
            hist4 <= 16'd0; hist5 <= 16'd0; hist6 <= 16'd0; hist7 <= 16'd0;
            hist8 <= 16'd0; hist9 <= 16'd0; hist10<= 16'd0; hist11<= 16'd0;
            hist12<= 16'd0; hist13<= 16'd0; hist14<= 16'd0; hist15<= 16'd0;
        end
        else begin
            // 按键：记下时刻，开始等待发声
            if (key_evt) begin
                t_press <= clk_cnt;
                pending <= 1'b1;
            end

            // 发声：结算一次延迟
            if (pending && sound_evt) begin
                pending  <= 1'b0;
                lat_last <= lat_now;
                if (lat_now < lat_min) lat_min <= lat_now;
                if (lat_now > lat_max) lat_max <= lat_now;
                lat_sum  <= lat_sum + lat_now;
                lat_cnt  <= lat_cnt + 16'd1;
                inc_hist(hidx);
            end

            if (clr) begin
                lat_min <= 32'hFFFF_FFFF;
                lat_max <= 32'd0;
                lat_sum <= 32'd0;
                lat_cnt <= 16'd0;
                hist0 <= 0; hist1 <= 0; hist2 <= 0; hist3 <= 0;
                hist4 <= 0; hist5 <= 0; hist6 <= 0; hist7 <= 0;
                hist8 <= 0; hist9 <= 0; hist10<= 0; hist11<= 0;
                hist12<= 0; hist13<= 0; hist14<= 0; hist15<= 0;
            end
        end
    end

    // ------------------------------------------------------------------
    // 显示保持：测完一个值后只显示 HOLD_CLK 时间，然后自动恢复 "——"
    //   （上位机的 flags.bit0 决定显示数字还是 "——"）
    // ------------------------------------------------------------------
    localparam HOLD_CLK = 27_000_000 * 2;   // 保持 2 秒

    reg [26:0] hold_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) hold_cnt <= 27'd0;
        else if (lat_cnt != 16'd0 && lat_last != 32'd0) begin
            // 有最新值：从它出现的时刻开始倒数
            if (hold_cnt == HOLD_CLK - 1) hold_cnt <= 27'd0;
            else                          hold_cnt <= hold_cnt + 27'd1;
        end
        else hold_cnt <= 27'd0;
    end

    // 只在"刚测完的 2 秒内"告诉上位机有数据
    assign has_data = (lat_cnt != 16'd0) && (hold_cnt != 27'd0 || lat_last != 32'd0);


endmodule
