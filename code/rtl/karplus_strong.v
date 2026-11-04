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
    input  wire                      slow_decay,   // 1=钢琴式慢衰减(y>>8) 0=拨弦式快衰减(y>>6)
    output reg  signed [15:0]        audio
);

    localparam DEPTH = 1 << DEPTH_LOG2;       // 512

    // ------------------------------------------------------------------
    // 1. 延迟线（BRAM）与指针
    // ------------------------------------------------------------------
    reg  [15:0] delay [0:DEPTH-1];
    reg  [DEPTH_LOG2-1:0] wr;

    reg  [DEPTH_LOG2-1:0] rd;
    // 延迟线必须是"同步读"，综合器才会把它映射到 BSRAM。
    // 之前写成 wire x_now = delay[rd]（异步读）时，Gowin 无法用 BRAM 实现，
    // 整块 512×16 退化成触发器，7 个 KS 实例直接把 DFF 顶到 18573（上限 15750）。
    // 代价：反馈路径多 1 拍延迟，音高约低 0.5%，实际听不出来。
    reg  [15:0] x_now_r;
    always @(posedge clk) x_now_r <= delay[rd];
    wire [15:0] x_now = x_now_r;

    reg  [15:0] x_prev;          // 上一个值，用于一阶低通

    // 写端口（★ 唯一管理 wr 的地方）
    // ------------------------------------------------------------------
    // 之前 wr 由主状态机递增、而 wr_data/wr_en 晚一拍才送到这里，
    // 结果是 **数据在拍 t 准备好、地址在拍 t 已经 +1**：
    // 第 k 个激励样本落进 delay[k+1]，delay[0] 永远没人写。
    // rd 又从 0 开始读，于是读到 4 态 x，x 进入反馈环路后污染整条延迟线
    // （板上的表现就是"按下去有音、随即突然没声"）。
    // 现在把 wr 的递增搬进写端口，地址与数据在同一拍绑定。
    // ------------------------------------------------------------------
    reg  [15:0] wr_data;
    reg         wr_en;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr <= {DEPTH_LOG2{1'b0}};
        end
        else if (trig) begin
            wr <= {DEPTH_LOG2{1'b0}};
        end
        else if (wr_en) begin
            delay[wr] <= wr_data;
            wr <= wr + 1'b1;
        end
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
    // 激励按音色分档：钢琴只过一级低通（保留高频 → 锤击的"嗒"），
    // 吉他过三级（噪声更圆润 → 拨弦的"噗"）。幅度钢琴 1/2、吉他 1/4。
    //
    // ⚠️ 幅度缩放必须对**有符号**量做算术右移。
    //    旧写法 `lp_c[15:0] >>> 1` 先把 17 位有符号截成 16 位无符号，
    //    移位就退化成逻辑右移 —— 负半周翻成接近 +32767 的大正数，
    //    等于给激励灌了一大堆满幅正脉冲。仿真里钢琴档 83 ms 就冲到
    //    32671（削波）、不到 1 s 直接归零，原因就在这里。
    wire [16:0]        exc_lp  = slow_decay ? lp1 : lp3;                    // 钢琴一级 / 吉他三级
    // 中心归零：先做无符号减法拿到补码位模式，再按有符号重新解释。
    // 不写成 $signed({1'b0, exc_lp[15:0]}) —— iverilog 对 $signed 里套拼接的
    // part-select 会报 "Unable to bind wire/reg/memory"，Gowin 却肯过，
    // 于是仿真永远跑不起来、只有综合能验。
    wire [16:0]        lp_c_u  = exc_lp - 17'd32768;
    wire signed [16:0] lp_c    = lp_c_u;
    // ⚠️ 幅度必须留够多声部叠加的余量。
    //    单个 KS 声部的稳态幅度 ≈ 激励幅度，4 声部相加就是 4 倍。
    //    2026-11-04 上一版写成钢琴 1/2（±16383），4 声部一叠加就是 65532，
    //    远超 16 位满幅 → 混音饱和后整段变成**方波**：频谱铺满全频段、
    //    波形是锯齿、听感既不像钢琴也不像吉他。
    //    现在钢琴 1/4、吉他 1/8：4 声部最坏 32764 / 16380，都不削波。
    wire signed [16:0] exc_s   = slow_decay ? (lp_c >>> 2) : (lp_c >>> 3);
    wire        [15:0] exc_val = exc_s[15:0];

    localparam S_IDLE  = 2'd0;
    localparam S_EXC   = 2'd1;      // 灌噪声
    localparam S_RUN   = 2'd2;      // 正常 KS 循环

    reg [1:0]  state;
    reg [9:0]  exc_cnt;
    // 2026-11-04：run_cnt 由 16 位扩到 18 位。
    // 慢衰减（钢琴 τ≈1.0 s）尾音到 1.14 s 时还有 ~31%（-10 dB），
    // 原来 16 位写死 60000 会在那儿**硬截断**，听起来是"咔"一声断掉。
    reg [17:0] run_cnt;
    reg [9:0]  len_q;               // 锁存本轮的 N

    // 尾音上限：钢琴放长到 ≈3.4 s（自然衰减到 -30 dB 以下），
    // 吉他保持 ≈0.95 s（那时已低于 0.7%，本来就没声了）。
    localparam [17:0] RUN_MAX_PIANO = 18'd180000;   // 180000 / 52734 ≈ 3.41 s
    localparam [17:0] RUN_MAX_PLUCK = 18'd50000;    //  50000 / 52734 ≈ 0.95 s
    wire [17:0] run_max = slow_decay ? RUN_MAX_PIANO : RUN_MAX_PLUCK;

    // 衰减后的反馈值
    // ------------------------------------------------------------------
    // 2026-11-04 第二轮：钢琴与吉他必须拉出**听感差距**
    //
    // 第一版只有衰减移位一个 bit 的差别（>>7 vs >>6，0.7 s vs 0.5 s），
    // 低通和激励完全一样 —— 用户实测"钢琴和吉他太接近"。
    // 现在三个维度同时区分：
    //
    //   维度        钢琴                      吉他
    //   ----------  ------------------------  --------------------------
    //   反馈低通    (a+b)/2       保留高频     (a+3b)/4     更闷、像木箱
    //   衰减        y-(y>>8) ≈1.4 s          y-(y>>5) ≈0.25 s
    //   激励        一级低通、幅度 1/2        三级低通、幅度 1/4
    //               （锤击的宽带瞬态）        （圆润的拨弦噪声）
    //
    // 两条曲线直流增益都是 1、环路增益都 <1，稳定。
    // ------------------------------------------------------------------
    // ★★ 2026-11-04 关键修复（低通级）：延迟线里是**补码**，16 位。
    //    旧写法 `{1'b0, x_now} + {1'b0, x_prev}` 是**零扩展**：
    //    -9909 被拼成 55627，低通结果 `lp` 直接变成 +27813，
    //    激励/反馈的负半周整段翻成正的大数，所以波形一直顶着削波、
    //    音色当然"闷且雷同"。低通必须显式符号扩展 + 算术右移。
    wire signed [15:0] x_now_s  = x_now;
    wire signed [15:0] x_prev_s = x_prev;

    wire signed [16:0] lp_piano = {x_now_s[15], x_now_s} + {x_prev_s[15], x_prev_s}; // a+b
    wire signed [15:0] lp_p     = lp_piano >>> 1;                                    // (a+b)/2
    wire signed [18:0] lp_pluck = {x_now_s[15], x_now_s[15], x_now_s}
                                + {x_prev_s[15], x_prev_s[15], x_prev_s}
                                + {x_prev_s[15], x_prev_s[15], x_prev_s}
                                + {x_prev_s[15], x_prev_s[15], x_prev_s};        // a+3b
    wire signed [15:0] lp_g     = lp_pluck[17:2];                                    // (a+3b)/4
    wire signed [15:0] lp       = slow_decay ? lp_p : lp_g;

    // 衰减也必须是有符号算术右移（上一棒已改成 >>>，保留）。
    wire signed [15:0] lp_s           = lp;
    wire signed [15:0] decayed_piano  = lp_s - (lp_s >>> 8);   // 钢琴：约 1.4 s
    wire signed [15:0] decayed_pluck  = lp_s - (lp_s >>> 5);   // 吉他：约 0.25 s
    // 松键阻尼：busy=0（键已松开且没踩延音踏板）时用快衰减，
    // 约 70 ms 听不见 —— 这才是钢琴"止音"的手感。
    wire signed [15:0] decayed_damper = lp_s - (lp_s >>> 3);
    wire signed [15:0] decayed = busy ? (slow_decay ? decayed_piano : decayed_pluck)
                                      : decayed_damper;


    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin

            rd       <= {DEPTH_LOG2{1'b0}};
            x_prev   <= 16'd0;
            wr_en    <= 1'b0;
            wr_data  <= 16'd0;
            lfsr     <= 16'hACE1;
            state    <= S_IDLE;
            exc_cnt  <= 10'd0;
            run_cnt  <= 18'd0;
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
                // 起音：进入激励阶段，指针归零（wr 由写端口清，见上）
                state   <= S_EXC;
                rd      <= {DEPTH_LOG2{1'b0}};
                exc_cnt <= 10'd0;
                run_cnt <= 18'd0;
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
                        exc_cnt <= exc_cnt + 10'd1;
                        if (exc_cnt + 10'd1 >= len_q) begin
                            state <= S_RUN;
                            // 激励从 delay[0] 顺序写到 delay[N-1]，最老的样本就是
                            // delay[0]，所以读指针直接从 0 开始（wr 由写端口推进）。
                            rd    <= {DEPTH_LOG2{1'b0}};
                        end
                    end

                    // ---- 正常循环 ----
                    S_RUN: begin
                        // 低通 + 衰减 → 写回
                        wr_data <= decayed;
                        wr_en   <= 1'b1;

                        x_prev <= x_now;           // 记住上一次读出值
                        rd     <= rd + 1'b1;

                        audio  <= $signed(x_now);  // 输出当前读出值

                        run_cnt <= run_cnt + 18'd1;
                        // 尾音自然衰减：不再因"松键"立即静音。
                        //   busy 只表示"这个声部是否被按键占用"，
                        //   而延迟线里的能量该衰减多久，就让它衰减多久。
                        //   弹完一个单音马上弹复音时，单音的余音不会被砍断。
                        //   上限按音色分档（run_max），见上面的 localparam。
                        if (run_cnt > run_max) begin
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
