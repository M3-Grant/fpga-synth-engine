// ============================================================================
//  模块名  : uart_stream.v
//  功能    : 给 PC 上位机（synth_viz.py）的串口帧发送器
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，27 MHz
//
//  ── 为什么有它 ────────────────────────────────────────────────────
//  `fpga_synth_host_viz` 上位机靠串口读 576 字节帧来画李萨如 / 频谱 /
//  波形 / 延迟面板。它的协议注释点名要 `uart_stream.v`，但仓库里从未实现。
//  本模块补上这一环。
//
//  ── 帧格式（与 synth_viz.py 严格一致）──────────────────────────────
//      [0]        0xA5              帧头1
//      [1]        0x5A              帧头2
//      [2]        timbre            音色 0..4
//      [3]        keys[7:0]         12 键状态低 8 位
//      [4]        {4'h0, keys[11:8]}
//      [5]        voices            活跃声部数
//      [6]        flags             bit0 = 有延迟数据（本模块恒 0）
//      [7]        effect            效果开关（本模块恒 0）
//      [8..519]   512 个采样        uint8 偏移二进制（0x80 = 零点）
//      [520..543] 延迟统计          暂填 0
//      [544..575] hist[16]          暂填 0
//
//  ── 延迟字段为什么是 0 ────────────────────────────────────────────
//  flags.bit0 = 0 时上位机显示 "—— ms"，不会误报。真实延迟要埋时间戳
//  统计（后续可加），这里如实置 0，不编造数据。
//
//  ── 时序 ──────────────────────────────────────────────────────────
//  音频 fs = 52734.375 Hz；每 7 个采样取 1 个 → 512 个采样约 68 ms 一帧，
//  即 ~14.7 fps，与上位机的 15 fps 吻合。
//  UART 115200 8N1：576 字节 × 10 bit = 5760 bit → 50 ms，仍在一帧周期内。
// ============================================================================
`timescale 1ns / 1ps

module uart_stream #(
    parameter CLK_HZ    = 27_000_000,
    parameter BAUD      = 115200,
    parameter DECIM     = 7,            // 每 7 个音频采样取 1 个
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
    output wire        frame_busy       // 调试：正在发帧（可接 LED）
);

    localparam AW = 9;                  // 512 深
    localparam BAUD_DIV = CLK_HZ / BAUD;   // 234 @27MHz（误差 0.16%）

    localparam S_IDLE = 2'd0;           // 累积采样，直到装满 512 个
    localparam S_LOAD = 2'd1;           // 装载一个字节
    localparam S_SEND = 2'd2;           // UART 发送该字节

    // ------------------------------------------------------------------
    // 状态
    // ------------------------------------------------------------------
    reg [1:0]      state;
    reg [AW-1:0]   wr_ptr;
    reg [AW-1:0]   rd_ptr;
    reg [2:0]      decim_cnt;
    reg [9:0]      byte_idx;
    reg            buf_we;

    reg [15:0]     baud_cnt;
    reg [3:0]      bit_idx;
    reg [9:0]      shift;
    reg            tx_busy;
    reg            tx_line;

    // ------------------------------------------------------------------
    // 采样缓冲（512 × 8bit，写口由主状态机控制，读口组合读出）
    // ------------------------------------------------------------------
    reg  [7:0]     buf_mem [0:511];
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
        else if (byte_idx == 10'd6)  cur_byte = 8'h00;    // flags
        else if (byte_idx == 10'd7)  cur_byte = 8'h00;    // effect
        else if (byte_idx < 10'd520) cur_byte = buf_rd_data;
        else                         cur_byte = 8'h00;    // 延迟 / 直方图
    end

    assign uart_tx    = tx_line;
    assign frame_busy = (state != S_IDLE);

    // ------------------------------------------------------------------
    // 主状态机（唯一驱动上述所有寄存器，避免多驱动）
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            wr_ptr    <= {AW{1'b0}};
            rd_ptr    <= {AW{1'b0}};
            decim_cnt <= 3'd0;
            byte_idx  <= 10'd0;
            buf_we    <= 1'b0;
            baud_cnt  <= 16'd0;
            bit_idx   <= 4'd0;
            shift     <= 10'h3FF;
            tx_busy   <= 1'b0;
            tx_line   <= 1'b1;
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

            // ---------- 帧状态机 ----------
            case (state)
                S_IDLE: begin
                    if (sample_en) begin
                        if (decim_cnt == DECIM - 1) begin
                            decim_cnt <= 3'd0;
                            buf_we    <= 1'b1;             // 存一个采样
                            if (wr_ptr == {AW{1'b1}}) begin
                                wr_ptr  <= {AW{1'b0}};
                                byte_idx <= 10'd0;
                                rd_ptr   <= {AW{1'b0}};
                                state    <= S_LOAD;        // 装满，开始发帧
                            end
                            else begin
                                wr_ptr <= wr_ptr + 1'b1;
                            end
                        end
                        else begin
                            decim_cnt <= decim_cnt + 1'b1;
                        end
                    end
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
                            state <= S_IDLE;
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

endmodule
