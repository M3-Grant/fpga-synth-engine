// ============================================================================
//  模块名  : karplus_strong.v
//  功能    : 拨弦乐器物理建模（Karplus-Strong 算法，单声部）
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，27 MHz
//
//  ── 为什么它能"像"拨弦乐器 ────────────────────────────────────────
//  这不是"拟合音色"，而是**弦振动方程的离散解**：
//      延迟线（长度 N = fs/f0）模拟"弦往返一次的时间"
//      一阶低通 (y[n] + y[n-1])/2 模拟"弦的阻尼"（高次谐波先衰减）
//      反馈系数 <1 模拟"能量损耗"
//  1983 年 Karplus & Strong 在 CCRMA 提出的算法，至今是所有物理建模
//  合成器的起点。物理上正确 → 听感上必然像吉他/古筝/竖琴。
//
//  ── 结构 ──────────────────────────────────────────────────────────
//      起音：往延迟线里灌 N 个白噪声采样（模拟"拨"的那一下）
//      之后：每采样读 delay[wr-N]，低通，×衰减，写回 delay[wr]
//
//  ── 资源 ──────────────────────────────────────────────────────────
//      512 × 16bit 的 BRAM（延迟线）。板上的 BSRAM 之前完全没用，正好给它。
//      不占 DSP（只有加法和移位）。
// ============================================================================
`timescale 1ns / 1ps

module karplus_strong #(
    parameter PHASE_BITS = 32,
    parameter DEPTH_LOG2 = 9,                 // 512 深延迟线
    parameter DECAY_SHIFT = 6                 // 衰减 y - y>>6（≈0.984/次）
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      sample_req,   // 音频采样率脉冲
    input  wire [PHASE_BITS-1:0]     fcw,          // 频率控制字（未直接用）
    input  wire [9:0]                ks_len,       // 延迟线长度 N = fs/f0
    input  wire                      trig,         // 起音脉冲
    input  wire                      busy,         // 1=发声 0=静音
    output reg  signed [15:0]        audio
);

    localparam DEPTH = 1 << DEPTH_LOG2;       // 512

    // ------------------------------------------------------------------
    // 1. 延迟线（BRAM）与指针
    // ------------------------------------------------------------------
    reg  [15:0] delay [0:DEPTH-1];
    reg  [DEPTH_LOG2-1:0] wr;

    reg  [DEPTH_LOG2-1:0] rd;
    wire [15:0] x_now = delay[rd];

    reg  [15:0] x_prev;          // 上一个值，用于一阶低通

    // 写端口
    reg  [15:0] wr_data;
    reg         wr_en;

    always @(posedge clk) begin
        if (wr_en) delay[wr] <= wr_data;
    end

    // ------------------------------------------------------------------
    // 2. 白噪声（LFSR），用于起音激励
    // ------------------------------------------------------------------
    reg [15:0] lfsr;
    wire       lfsr_fb = lfsr[0] ^ lfsr[2] ^ lfsr[3] ^ lfsr[5];

    // ------------------------------------------------------------------
    // 3. 主状态机
    // ------------------------------------------------------------------
    // 激励噪声：两级低通（更"深沉"）+ 有符号中心化 + 降到 1/4 幅度
    //   一级低通听起来还是"沙沙的"，两级后才有"低频的拨弦感"。
    reg  [15:0] lfsr_prev, lfsr_prev2, lfsr_prev3;
    wire [16:0] lp1 = ({1'b0, lfsr}      + {1'b0, lfsr_prev})  >> 1;
    wire [16:0] lp2 = (lp1               + {1'b0, lfsr_prev2}) >> 1;
    wire [16:0] lp3 = (lp2               + {1'b0, lfsr_prev3}) >> 1;
    wire signed [16:0] lp_c = $signed({1'b0, lp3[15:0]}) - 17'sd32768;  // 中心归零
    wire        [15:0] exc_val = lp_c[15:0] >>> 2;                      // 幅度 1/4

    localparam S_IDLE  = 2'd0;
    localparam S_EXC   = 2'd1;      // 灌噪声
    localparam S_RUN   = 2'd2;      // 正常 KS 循环

    reg [1:0]  state;
    reg [9:0]  exc_cnt;
    reg [15:0] run_cnt;
    reg [9:0]  len_q;               // 锁存本轮的 N

    // 衰减后的反馈值
    // 低通：原来用 (a+b)/2（截止偏高，声音偏"亮"），改成 (a+3b)/4
    //   —— 截止更低、高频掉得更快，听感更柔；直流增益仍为 1。
    wire [17:0] lp_sum = ({2'b0, x_now} + {2'b0, x_prev} * 18'd3);
    wire [15:0] lp     = lp_sum[17:2];                        // (a+3b)/4
    wire        [15:0] decayed = lp - (lp >> DECAY_SHIFT);    // ×(1-2^-s)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr       <= {DEPTH_LOG2{1'b0}};
            rd       <= {DEPTH_LOG2{1'b0}};
            x_prev   <= 16'd0;
            wr_en    <= 1'b0;
            wr_data  <= 16'd0;
            lfsr     <= 16'hACE1;
            state    <= S_IDLE;
            exc_cnt  <= 10'd0;
            run_cnt  <= 10'd0;
            len_q    <= 10'd200;
            audio    <= 16'sd0;
        end
        else begin
            wr_en <= 1'b0;

            // LFSR 每周期都跑（噪声源）
            lfsr      <= {lfsr_fb, lfsr[15:1]};
            lfsr_prev  <= lfsr;
            lfsr_prev2 <= lfsr_prev;
            lfsr_prev3 <= lfsr_prev2;

            if (trig) begin
                // 起音：进入激励阶段，指针归零
                state   <= S_EXC;
                wr      <= {DEPTH_LOG2{1'b0}};
                rd      <= {DEPTH_LOG2{1'b0}};
                exc_cnt <= 10'd0;
                run_cnt <= 10'd0;
                len_q   <= ks_len;
                x_prev  <= 16'd0;
                audio   <= 16'sd0;
            end
            else if (sample_req) begin
                case (state)
                    // ---- 灌噪声：写满 N 个采样 ----
                    S_EXC: begin
                        // 激励噪声先做一阶低通 —— 原始白噪声直接灌进去听起来像
                        // "在弦上使劲摩擦"，低通后才像"拨一下"。
                        wr_data <= exc_val;
                        wr_en   <= 1'b1;
                        wr      <= wr + 1'b1;
                        exc_cnt <= exc_cnt + 10'd1;
                        if (exc_cnt + 10'd1 >= len_q) begin
                            state <= S_RUN;
                            rd    <= wr - len_q[DEPTH_LOG2-1:0];   // 读指针落后 N（同宽相减）
                        end
                    end

                    // ---- 正常循环 ----
                    S_RUN: begin
                        // 低通 + 衰减 → 写回
                        wr_data <= decayed;
                        wr_en   <= 1'b1;

                        x_prev <= x_now;           // 记住上一次读出值
                        wr     <= wr + 1'b1;
                        rd     <= rd + 1'b1;

                        audio  <= $signed(x_now);  // 输出当前读出值

                        run_cnt <= run_cnt + 16'd1;
                        // 尾音自然衰减：不再因"松键"立即静音。
                        //   busy 只表示"这个声部是否被按键占用"，
                        //   而延迟线里的能量该衰减多久，就让它衰减多久。
                        //   弹完一个单音马上弹复音时，单音的余音不会被砍断。
                        //   32000 采样 ≈ 0.61 秒（尾音时长）
                        if (run_cnt > 16'd32000) begin
                            state <= S_IDLE;
                            audio <= 16'sd0;
                        end
                    end

                    default: begin
                        state <= S_IDLE;
                        audio <= 16'sd0;
                    end
                endcase
            end
        end
    end

endmodule
