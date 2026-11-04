// ============================================================================
//  模块名  : uart_stream.v
//  功能    : 给 PC 上位机（Web UI / synth_viz.py）的串口帧发送器
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，27 MHz
//
//  ── 帧格式（与 PCM5102A 之后的 Web UI 严格一致）─────────────────────
//      [0]        0xA5              帧头1
//      [1]        0x5A              帧头2
//      [2]        timbre            音色 0..5
//      [3]        keys[7:0]         12 键状态低 8 位
//      [4]        {4'h0, keys[11:8]}
//      [5]        voices            活跃声部数
//      [6]        flags             bit0 = 有延迟数据
//      [7]        effect            效果开关（本模块恒 0）
//      [8..519]   512 个采样        uint8 偏移二进制（0x80 = 零点）
//      [520..535] 延迟统计          last/min/max/sum
//      [536..539] lat_cnt / 预留
//      [540..543] scan_period
//      [544..567] 12 音计数
//
//  ── 2026-11-01 v2：双缓冲（ping-pong）────────────────────────────────
//  旧版问题：只在 S_IDLE 里累积采样，发送那 50 ms 采不到样，
//  一帧周期 = 512×DECIM/fs + 50 ms = 68 + 50 = 118 ms -> 8.5 fps，
//  而且每帧之间断 50 ms，波形不连续。
//
//  现在：两个 512 深 bank。发送 A 的同时继续往 B 写，一个 bank 写满
//  立刻切去发它。帧周期 = max(采样时间, 发送时间) = 68 ms -> 14.7 fps，
//  采样数据连续，不再有断档。
//
//  ── 时序 ──────────────────────────────────────────────────────────
//  音频 fs = 52734.375 Hz；DECIM=7 时 512 点覆盖 68 ms。
//  UART 115200 8N1：576 字节 × 10 bit = 5760 bit -> 50 ms < 68 ms，
//  所以发送总能在一个采样窗口内完成，不会丢 bank。
// ============================================================================
`timescale 1ns / 1ps

module uart_stream #(
    parameter CLK_HZ    = 27_000_000,
    parameter BAUD      = 115200,
    parameter DECIM     = 7,            // 每 DECIM 个音频采样取 1 个
    parameter FRAME_LEN = 576
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_en,       // 音频采样率脉冲（52734 Hz）
    input  wire signed [15:0] audio,    // 当前音频样本
    input  wire [11:0] keys,            // 12 键状态
    input  wire [2:0]  timbre,          // 音色
    input  wire [2:0]  voices,          // 活跃声部数
    output wire        uart_tx,         // → USB-TTL 的 RXD
    output wire        frame_busy,      // 调试：正在发帧（可接 LED）
    // ---- 延迟统计（来自 latency_meter.v）----
    input  wire [31:0] lat_last,
    input  wire [31:0] lat_min,
    input  wire [31:0] lat_max,
    input  wire [31:0] lat_sum,
    input  wire [15:0] lat_cnt,
    input  wire        lat_valid,       // 1 = 已有测量数据
    input  wire [15:0] hist0, hist1, hist2, hist3,
    input  wire [15:0] hist4, hist5, hist6, hist7,
    input  wire [15:0] hist8, hist9, hist10, hist11,
    input  wire [15:0] hist12, hist13, hist14, hist15,
    // ---- 红外诊断（占用帧尾保留字节 568~571）----
    input  wire [1:0]  ir_hand,          // bit0 = IR#1(85), bit1 = IR#2(73)，1 = 有手
    input  wire [7:0]  ir_gesture_cnt,   // 有效挥手累计次数
    input  wire [7:0]  ir_short_cnt,     // 挥手过短被拒次数
    input  wire [7:0]  ir_long_cnt       // 挥手过长被拒次数
);

    localparam AW = 10;                     // 2 × 512 双 bank
    localparam BAUD_DIV = CLK_HZ / BAUD;    // 234 @27MHz/115200（误差 0.16%）
                                            // 29 @27MHz/921600（误差 +1.0%，实测无丢字节）
    localparam [7:0] DECIM_BYTE = DECIM;    // 写进帧的 [538]，让上位机知道抽取比

    localparam S_IDLE = 2'd0;           // 空闲：等一个 bank 写满
    localparam S_LOAD = 2'd1;           // 装载一个字节
    localparam S_SEND = 2'd2;           // UART 发送该字节

    // ------------------------------------------------------------------
    // 状态
    // ------------------------------------------------------------------
    reg [1:0]      state;
    reg [AW-1:0]   wr_ptr;              // bit9 = 写 bank
    reg [AW-1:0]   rd_ptr;              // bit9 = 读 bank
    reg [2:0]      decim_cnt;
    reg [9:0]      byte_idx;
    reg            buf_we;

    reg            tx_active;           // 正在发送某个 bank
    reg            pending;             // 另一个 bank 已写满待发
    reg            pending_bank;        // 待发 bank 号

    reg [15:0]     baud_cnt;
    reg [3:0]      bit_idx;
    reg [9:0]      shift;
    reg            tx_busy;
    reg            tx_line;

    // ------------------------------------------------------------------
    // 采样缓冲（2 × 512 × 8bit）
    // ------------------------------------------------------------------
    reg  [7:0]     buf_mem [0:1023];
    wire [7:0]     buf_rd_data = buf_mem[rd_ptr];
    wire [7:0]     audio_u8    = audio[15:8] ^ 8'h80;  // 高 8 位 → 偏移二进制

    always @(posedge clk) begin
        if (buf_we) buf_mem[wr_ptr] <= audio_u8;
    end

    // ------------------------------------------------------------------
    // 当前字节（按索引选择，纯组合）
    // ------------------------------------------------------------------
    reg [7:0] cur_byte;

    always @(*) begin
        if      (byte_idx == 10'd0)  cur_byte = 8'hA5;
        else if (byte_idx == 10'd1)  cur_byte = 8'h5A;
        else if (byte_idx == 10'd2)  cur_byte = {5'b0, timbre};
        else if (byte_idx == 10'd3)  cur_byte = keys[7:0];
        else if (byte_idx == 10'd4)  cur_byte = {4'b0, keys[11:8]};
        else if (byte_idx == 10'd5)  cur_byte = {5'b0, voices};
        else if (byte_idx == 10'd6)  cur_byte = {7'b0, lat_valid};  // flags.bit0
        else if (byte_idx == 10'd7)  cur_byte = 8'h00;              // effect
        else if (byte_idx < 10'd520) cur_byte = buf_rd_data;
        else if (byte_idx < 10'd524) cur_byte = lat_last[((byte_idx - 10'd520)*8) +: 8];
        else if (byte_idx < 10'd528) cur_byte = lat_min [((byte_idx - 10'd524)*8) +: 8];
        else if (byte_idx < 10'd532) cur_byte = lat_max [((byte_idx - 10'd528)*8) +: 8];
        else if (byte_idx < 10'd536) cur_byte = lat_sum [((byte_idx - 10'd532)*8) +: 8];
        else if (byte_idx < 10'd538) cur_byte = lat_cnt [((byte_idx - 10'd536)*8) +: 8];
        // [538..539] = 抽取比 DECIM（上位机据此还原频率轴；0 表示老固件按 7 处理）
        else if (byte_idx < 10'd540) cur_byte = (byte_idx == 10'd538) ? DECIM_BYTE : 8'h00;
        else if (byte_idx < 10'd544) cur_byte = 8'h00;              // scan_period（暂 0）
        else if (byte_idx < 10'd568) begin
            // 12 音计数 [544..567]：每个 u16，索引 = byte_idx[4:1]
            case (byte_idx[4:1])
                4'd0 : cur_byte = byte_idx[0] ? nc0 [15:8] : nc0 [7:0];
                4'd1 : cur_byte = byte_idx[0] ? nc1 [15:8] : nc1 [7:0];
                4'd2 : cur_byte = byte_idx[0] ? nc2 [15:8] : nc2 [7:0];
                4'd3 : cur_byte = byte_idx[0] ? nc3 [15:8] : nc3 [7:0];
                4'd4 : cur_byte = byte_idx[0] ? nc4 [15:8] : nc4 [7:0];
                4'd5 : cur_byte = byte_idx[0] ? nc5 [15:8] : nc5 [7:0];
                4'd6 : cur_byte = byte_idx[0] ? nc6 [15:8] : nc6 [7:0];
                4'd7 : cur_byte = byte_idx[0] ? nc7 [15:8] : nc7 [7:0];
                4'd8 : cur_byte = byte_idx[0] ? nc8 [15:8] : nc8 [7:0];
                4'd9 : cur_byte = byte_idx[0] ? nc9 [15:8] : nc9 [7:0];
                4'd10: cur_byte = byte_idx[0] ? nc10[15:8] : nc10[7:0];
                default: cur_byte = byte_idx[0] ? nc11[15:8] : nc11[7:0];
            endcase
        end
        else if (byte_idx == 10'd568) cur_byte = {6'b0, ir_hand};
        else if (byte_idx == 10'd569) cur_byte = ir_gesture_cnt;
        else if (byte_idx == 10'd570) cur_byte = ir_short_cnt;
        else if (byte_idx == 10'd571) cur_byte = ir_long_cnt;
        else cur_byte = 8'h00;                                     // 572~575 保留
    end

    assign uart_tx    = tx_line;
    assign frame_busy = tx_active | pending;

    // ------------------------------------------------------------------
    // 主状态机
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            wr_ptr       <= {AW{1'b0}};
            rd_ptr       <= {AW{1'b0}};
            decim_cnt    <= 3'd0;
            byte_idx     <= 10'd0;
            buf_we       <= 1'b0;
            tx_active    <= 1'b0;
            pending      <= 1'b0;
            pending_bank <= 1'b0;
            baud_cnt     <= 16'd0;
            bit_idx      <= 4'd0;
            shift        <= 10'h3FF;
            tx_busy      <= 1'b0;
            tx_line      <= 1'b1;
        end
        else begin
            buf_we <= 1'b0;

            // ---------- UART 位定时（独立于帧状态机）----------
            if (tx_busy) begin
                if (baud_cnt == BAUD_DIV - 1) begin
                    baud_cnt <= 16'd0;
                    tx_line  <= shift[0];
                    shift    <= {1'b1, shift[9:1]};
                    if (bit_idx == 4'd9) begin
                        bit_idx <= 4'd0;
                        tx_busy <= 1'b0;
                    end
                    else begin
                        bit_idx <= bit_idx + 1'b1;
                    end
                end
                else begin
                    baud_cnt <= baud_cnt + 16'd1;
                end
            end
            else begin
                tx_line <= 1'b1;               // 空闲高电平
            end

            // ---------- 采样：一直接收，不再只在空闲时采 ----------
            // pending 时暂存（两个 bank 都在用时丢掉极少量采样），
            // 正常情况下发送 50 ms < 采样 68 ms，几乎不会触发。
            if (sample_en && !pending) begin
                if (decim_cnt == DECIM - 1) begin
                    decim_cnt <= 3'd0;
                    buf_we    <= 1'b1;
                    wr_ptr    <= wr_ptr + 1'b1;
                    if (wr_ptr[8:0] == 9'd511) begin
                        // 刚好写满 wr_ptr[9] 这个 bank
                        if (!tx_active) begin
                            rd_ptr    <= {wr_ptr[9], 9'd0};
                            byte_idx  <= 10'd0;
                            tx_active <= 1'b1;
                            state     <= S_LOAD;
                        end
                        else begin
                            pending_bank <= wr_ptr[9];
                            pending      <= 1'b1;
                        end
                    end
                end
                else begin
                    decim_cnt <= decim_cnt + 1'b1;
                end
            end

            // ---------- 帧状态机 ----------
            case (state)
                S_IDLE: begin
                    // 采样在状态机外持续进行，这里什么都不做
                end

                S_LOAD: begin
                    if (byte_idx >= 10'd8 && byte_idx < 10'd520)
                        rd_ptr <= rd_ptr + 1'b1;           // 采样段推进读指针
                    shift    <= {1'b1, cur_byte, 1'b0};    // stop | data | start
                    bit_idx  <= 4'd0;
                    baud_cnt <= 16'd0;
                    tx_busy  <= 1'b1;
                    state    <= S_SEND;
                end

                S_SEND: begin
                    if (!tx_busy) begin
                        if (byte_idx == FRAME_LEN[9:0] - 10'd1) begin
                            tx_active <= 1'b0;
                            if (pending) begin
                                rd_ptr    <= {pending_bank, 9'd0};
                                byte_idx  <= 10'd0;
                                tx_active <= 1'b1;
                                pending   <= 1'b0;
                                state     <= S_LOAD;
                            end
                            else begin
                                state <= S_IDLE;
                            end
                        end
                        else begin
                            byte_idx <= byte_idx + 1'b1;
                            state    <= S_LOAD;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ==================================================================
    // 12 音按键计数（keys 上升沿）
    // 注意：实测硬件上这 12 个计数器会"一起 +1"（综合器合并了同构逻辑），
    //       上位机不要依赖它，UI 端用 PC 统计。这里保留只为协议完整。
    // ==================================================================
    (* keep *) reg [11:0] keys_prev;
    (* keep *) reg [15:0] nc0, nc1, nc2, nc3, nc4, nc5;
    (* keep *) reg [15:0] nc6, nc7, nc8, nc9, nc10, nc11;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            keys_prev <= 12'd0;
            nc0 <= 16'd0; nc1 <= 16'd0; nc2 <= 16'd0; nc3 <= 16'd0;
            nc4 <= 16'd0; nc5 <= 16'd0; nc6 <= 16'd0; nc7 <= 16'd0;
            nc8 <= 16'd0; nc9 <= 16'd0; nc10<= 16'd0; nc11<= 16'd0;
        end
        else begin
            keys_prev <= keys;
            if (keys[0]  && !keys_prev[0])  nc0  <= nc0  + 16'd1;
            if (keys[1]  && !keys_prev[1])  nc1  <= nc1  + 16'd1;
            if (keys[2]  && !keys_prev[2])  nc2  <= nc2  + 16'd1;
            if (keys[3]  && !keys_prev[3])  nc3  <= nc3  + 16'd1;
            if (keys[4]  && !keys_prev[4])  nc4  <= nc4  + 16'd1;
            if (keys[5]  && !keys_prev[5])  nc5  <= nc5  + 16'd1;
            if (keys[6]  && !keys_prev[6])  nc6  <= nc6  + 16'd1;
            if (keys[7]  && !keys_prev[7])  nc7  <= nc7  + 16'd1;
            if (keys[8]  && !keys_prev[8])  nc8  <= nc8  + 16'd1;
            if (keys[9]  && !keys_prev[9])  nc9  <= nc9  + 16'd1;
            if (keys[10] && !keys_prev[10]) nc10 <= nc10 + 16'd1;
            if (keys[11] && !keys_prev[11]) nc11 <= nc11 + 16'd1;
        end
    end
endmodule
