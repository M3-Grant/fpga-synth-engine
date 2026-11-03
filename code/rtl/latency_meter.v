// ============================================================================
//  模块名  : latency_meter.v
//  功能    : 演奏延迟统计器 —— 用 27 MHz 计数器精确测量"演奏动作 → 音频输出"
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)
//
//  ── 为什么需要它 ──────────────────────────────────────────────────
//  比赛要求"控制信号到音频输出总延迟 ≤10ms（拓展 ≤5ms 且确定性无抖动）"。
//  用示波器只能抓一次瞬时值，用 PC 软件打点又会被串口缓冲搅浑。
//  本模块在 FPGA 内部用 27 MHz 计数器直接相减，分辨率 37 ns，
//  并且把统计量（最小/最大/平均/次数/直方图）交给上位机画图 ——
//  连按几十下就能看到延迟分布，这才是"确定性无抖动"的可视化证据。
//
//  ── 测量的时间窗口（重要，答辩时要讲清楚）────────────────────────
//      起点 touch_evt  : FPGA 第一次从 TTP229 读回"某键按下"的那一拍
//                        （不含触摸芯片内部扫描时间，也不含主机轮询间隔
//                          —— 这两个量无法在 FPGA 内部测出，另用
//                          scan_period 单独上报，由上位机加总）
//      终点 frame_tick : 消抖后的 note-on 生效之后，第一个音频帧起点
//                        （即新音符的第一个样本真正上路的那一刻）
//      → lat = 扫描同步 + 消抖 + 帧对齐，正好是"我们能优化、也必须证明"的那一段
//
//  ── 输出量 ────────────────────────────────────────────────────────
//      lat_last/min/max/sum/cnt : 单位是 27 MHz 时钟周期
//      hist_flat                : 16 个 16 位计数器，bin 宽 2^BIN_SHIFT 个周期
//                                 BIN_SHIFT=16 → 65536 clk = 2.427 ms/bin
//                                 16 个 bin 覆盖 0~38.8 ms，超出全部计入最后一格
//      scan_period              : 两次 TTP229 扫描完成之间的周期数
//                                 （= 按键采样间隔，决定"最坏情况"的那一半）
// ============================================================================
`timescale 1ns / 1ps

module latency_meter #(
    parameter HIST_BINS  = 16,          // 必须为 16（bin 索引取 4 位）
    parameter BIN_SHIFT  = 16,          // 每格 2^16 = 65536 clk = 2.427 ms
    parameter TIMEOUT    = 1_350_000    // 50 ms：超时放弃，防止 armed 卡死
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        touch_evt,       // 原始触摸数据变化（按下）—— 起点
    input  wire        note_on_evt,     // 消抖后的 note-on
    input  wire        frame_tick,      // 音频帧起点（LRCK 上升沿）
    input  wire        scan_tick,       // TTP229 一轮扫描完成
    // ---- 延迟统计（单位：clk 周期）----
    output reg  [31:0] lat_last,
    output reg  [31:0] lat_min,         // 0xFFFFFFFF = 还没有数据
    output reg  [31:0] lat_max,
    output reg  [31:0] lat_sum,         // 32 位自然回绕，上位机按 cnt 取模还原
    output reg  [15:0] lat_cnt,
    output reg  [HIST_BINS*16-1:0] hist_flat,
    // ---- 扫描周期 ----
    output reg  [31:0] scan_period
);

    // ==================================================================
    // 1. 自由运行计数器（27 MHz → 每 37.04 ns 加一）
    // ==================================================================
    reg [31:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cnt <= 32'd0;
        else        cnt <= cnt + 32'd1;
    end

    // ==================================================================
    // 2. 测时状态机：IDLE → ARMED（等消抖）→ WAITING（等音频帧）→ 记录
    // ==================================================================
    reg        armed;
    reg        waiting;
    reg [31:0] t0;
    reg [31:0] last_scan;

    wire [31:0] lat = cnt - t0;

    // 直方图 bin：取第 BIN_SHIFT 位起的 4 位，溢出统一进最后一格
    wire        ovf     = |(lat >> (BIN_SHIFT + 4));
    wire [3:0]  bin     = ovf ? 4'd15 : lat[BIN_SHIFT+3 : BIN_SHIFT];
    wire [15:0] hval    = hist_flat[{bin, 4'd0} +: 16];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            armed       <= 1'b0;
            waiting     <= 1'b0;
            t0          <= 32'd0;
            last_scan   <= 32'd0;
            lat_last    <= 32'd0;
            lat_min     <= 32'hFFFF_FFFF;
            lat_max     <= 32'd0;
            lat_sum     <= 32'd0;
            lat_cnt     <= 16'd0;
            hist_flat   <= {(HIST_BINS*16){1'b0}};
            scan_period <= 32'd0;
        end
        else begin
            // ---------- 起点 ----------
            // 每次新的按键事件都重新计时：touch_evt 现在由顶层做成"新按下沿"，
            // 这里不再用 !armed 门控，避免上一次未完成的测量把 t0 拖住。
            if (touch_evt) begin
                t0      <= cnt;
                armed   <= 1'b1;
                waiting <= 1'b0;
            end
            // ---------- 消抖后的 note-on 到来，开始等音频帧 ----------
            else if (armed && note_on_evt) begin
                waiting <= 1'b1;
            end

            // ---------- 终点：该音符第一个样本上路 ----------
            if (armed && waiting && frame_tick) begin
                armed     <= 1'b0;
                waiting   <= 1'b0;
                lat_last  <= lat;
                if (lat < lat_min) lat_min <= lat;
                if (lat > lat_max) lat_max <= lat;
                lat_sum   <= lat_sum + lat;
                lat_cnt   <= lat_cnt + 16'd1;
                hist_flat[{bin, 4'd0} +: 16] <= hval + 16'd1;
            end
            // ---------- 超时保护：没等到 note-on（抖动/误触）就放弃 ----------
            else if (armed && ((cnt - t0) > TIMEOUT)) begin
                armed   <= 1'b0;
                waiting <= 1'b0;
            end

            // ---------- 按键采样间隔（两次扫描完成之间）----------
            if (scan_tick) begin
                scan_period <= cnt - last_scan;
                last_scan   <= cnt;
            end
        end
    end

endmodule
