// ============================================================================
//  模块名  : piano_engine.v
//  功能    : 钢琴音色引擎 —— 加法合成（6 次谐波）+ 钢琴式衰减包络
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，主时钟 27 MHz
//
//  ── 为什么钢琴需要"谐波"──────────────────────────────────────────
//  三角波只有奇次谐波（1/n²），听起来像长笛；方波奇次 1/n，像单簧管。
//  钢琴的频谱是 **1、2、3、4、5、6 次全有**，幅度大致按 1/h^1.5 衰减
//  （实测钢琴：基波最强，2 次约 1/3，3 次约 1/5，往上快速减弱）。
//  更关键的是 **高次谐波衰减得比基波快得多** —— 所以钢琴声是
//  "敲下去亮、随后变暗"，这个变化正是三角波/方波做不出来的。
//
//  ── 本模块做什么 ──────────────────────────────────────────────────
//  每个声部 6 个谐波振荡器（相位累加器），谐波 h 的频率 = h × f0：
//      · 幅度权重   A[h] = 1/h^1.5 形状，归一化到 ΣA[h] = 65536
//      · 独立包络   env[h] 逐采样指数衰减，h 越大衰减越快（音色变暗）
//      · 起音       note-on 时 env 在约 1.2 ms 内线性升到 A[h]（模拟琴棰）
//      · 止音       松键后 env 用 damper 速率快速归零（约 70 ms 听不见）
//  4 个声部 × 6 谐波 = 24 路，串行乘加（一个乘法器 + 一个累加器），
//  资源远小于 24 个并行乘法器。
//
//  ── 正弦怎么来（不用 BSRAM、不用 $readmemh）───────────────────────
//  32 点正弦表 + 一阶线性插值 = 等效 512 点精度，谐波失真约 -60 dB。
//  表用 case 常量写成，综合成 LUT（或 BSRAM），不依赖外部 .mem 文件
//  （Gowin 综合对 $readmemh 的支持不稳定，踩过坑就绕开）。
//
//  ── 时序（关键）───────────────────────────────────────────────────
//  i2s_tx 的 sample_req 在右声道 LSB 处脉冲，到下一帧锁存样本还有
//  16 个 BCK = 16 × 2 × BCK_HALF = 128 clk（BCK_HALF=4）。
//  本模块用 28 clk 算完 24 路（st 0..27，三级流水），余量 4.5 倍。
//  audio 在下一个 sample_req 之前保持有效，正好被 i2s_tx 在帧起点取走。
//
//  ── 位宽与峰值（务必看懂，改参数时要重算）─────────────────────────
//  单个正弦项 = sin16(±32767) × env(0..A[h]) >> 16  →  |项| ≤ A[h]/2
//  单声部 6 项全同相（理论上界） = ΣA[h]/2 = 32768
//  4 声部          = 131072 → 累加器 24 位足够
//  输出前 >>> 2    = 4 声部最坏 32768，饱和逻辑兜底；单声部实测峰值约
//                    5~6k（约为 beta.2.1 三角波的 2.5~3 倍）
//
//  作者    : 2026-10-18 钢琴音色迭代
// ============================================================================
module piano_engine #(
    parameter VOICE_NUM  = 4,
    parameter HARM_NUM   = 6,
    // 音色预设：0=钢琴(1/h^1.5 全谐波, 快衰减)
    //           1=长笛(基波+微弱泛音, 极慢衰减)
    parameter TIMBRE     = 0,          // 谐波数（1..6 次）
    parameter PHASE_BITS = 32
)(
    input  wire                            clk,
    input  wire                            rst_n,
    input  wire                            sample_req,     // 每帧一个 clk 脉冲
    input  wire [VOICE_NUM*PHASE_BITS-1:0] voice_fcw,      // 各声部基频控制字
    input  wire [VOICE_NUM-1:0]            voice_trig,     // note-on 单周期脉冲
    input  wire [VOICE_NUM-1:0]            voice_busy,     // 该声部正在发声
    output reg  signed [15:0]              audio           // 混音后的音频样本
);

    localparam TOTAL = VOICE_NUM * HARM_NUM;      // 24 路

    // ------------------------------------------------------------------
    // 1. 谐波权重 / 衰减速率（与 h 一一对应的常量表）
    //    A[h] 之和 = 65536，正好是 16 位满量程，方便归一化
    // ------------------------------------------------------------------
    function [15:0] harm_weight;
        input [3:0] h;
        begin
            if (TIMBRE == 3) begin
                // ---- 马林巴：非谐性谐波，高次加权以取得"清脆" ----
                //   1 : 0.50 : 0.28 : 0.13（越往高频份量越足）
                case (h)
                    4'd1: harm_weight = 16'd30000;   // 1.000
                    4'd2: harm_weight = 16'd15000;   // 0.500（3.9 倍频）
                    4'd3: harm_weight = 16'd8400;    // 0.280（9.2 倍频）
                    4'd4: harm_weight = 16'd12136;   // 0.405（16.3 倍频）
                    default: harm_weight = 16'd0;
                endcase
            end
            else if (TIMBRE == 2) begin
                // ---- 管风琴：6 个谐波全开（近似等权重）----
                //   真实管风琴 = 不同长度的管子同时发声 = 谐波叠加，
                //   这正是加法合成最擅长的乐器。
                //   和 = 65536
                //   音栓式配比：只叠八度关系（8'/4'/2'）+ 少量五度(2 2/3')
                //   1 : 0.50 : 0.11 : 0.21 : 0 : 0
                //   （之前把 1~6 次全开且均匀，那其实是锯齿波，听起来像"喇叭"）
                case (h)
                    4'd1: harm_weight = 16'd36000;   // 8'   基波，主导
                    4'd2: harm_weight = 16'd18000;   // 4'
                    4'd3: harm_weight = 16'd4000;    // 2 2/3' 五度音栓（少量）
                    4'd4: harm_weight = 16'd7536;    // 2'
                    4'd5: harm_weight = 16'd0;       // 关
                    4'd6: harm_weight = 16'd0;       // 关
                    default: harm_weight = 16'd0;
                endcase
            end
            else if (TIMBRE == 1) begin
                // ---- 长笛：几乎纯正弦，只有一点点 2/3 次泛音 ----
                //   1 : 0.08 : 0.012，和 = 65536（归一化）
                case (h)
                    4'd1: harm_weight = 16'd60000;   // 1.000
                    4'd2: harm_weight = 16'd4800;    // 0.080
                    4'd3: harm_weight = 16'd736;     // 0.012
                    default: harm_weight = 16'd0;
                endcase
            end
            else begin
                // ---- 钢琴：1/h^1.5 全谐波 ----
                case (h)
                    4'd1: harm_weight = 16'd35840;   // 1.000
                    4'd2: harm_weight = 16'd12672;   // 0.354
                    4'd3: harm_weight = 16'd6912;    // 0.193
                    4'd4: harm_weight = 16'd4480;    // 0.125
                    4'd5: harm_weight = 16'd3200;    // 0.089
                    4'd6: harm_weight = 16'd2432;    // 0.068
                    default: harm_weight = 16'd0;
                endcase
            end
        end
    endfunction

    // 指数衰减的右移位数：env -= env>>s 的时间常数 = 2^s 个采样
    //   s=14 → 16384 采样 ≈ 310 ms（基波，约 2.2 s 衰到 -60 dB）
    //   s=11 →  2048 采样 ≈  39 ms（6 次谐波，约 0.27 s）
    // ------------------------------------------------------------------
    // 谐波倍率（×128 定点）：整数倍用于长笛/管风琴，非整数倍用于马林巴/钢琴
    //   马林巴的真实频谱是 1 : 3.9 : 9.2（非谐性）——这正是它"木质"的来源，
    //   用整数倍谐波是做不出来的（那会变成风琴/喇叭）。
    //
    //   ★ 2026-11-04：钢琴改用**非谐倍率**（用户指出的关键点）
    //     真实钢琴弦有弯曲刚度，泛音被拉伸：f_n ≈ n·f0·sqrt(1 + B·n²)，
    //     低音区 B ≈ 1e-4、中音区 B ≈ 3e-4、高音区可到 1e-2。
    //     严格整数倍（1:2:3:4:5:6）是"理想弦"，听起来像竖琴/风琴，永远不像钢琴。
    //     这里取 B = 3e-4，×128 定点：
    //       n=1 → 128      （1.000）
    //       n=2 → 256      （2.0000，理论 2.0012）
    //       n=3 → 385      （3.0078，理论 3.0041）
    //       n=4 → 513      （4.0078，理论 4.0096）
    //       n=5 → 642      （5.0156，理论 5.0187）
    //       n=6 → 772      （6.0313，理论 6.0323）
    //     精度 1/128 换算成频率是 0.78% 一个 LSB，对高次谐波刚好能把拉伸做出来。
    // ------------------------------------------------------------------
    function [11:0] harm_ratio;   // 12 位 ×128 定点，最大支持 31.9 倍
        input [3:0] h;
        begin
            if (TIMBRE == 3) begin
                // 马林巴的振动模态：1 : 3.9 : 9.2 : 16.3（越往上越"清脆"）
                case (h)
                    4'd1: harm_ratio = 12'd128;   // 1.000
                    4'd2: harm_ratio = 12'd496;   // 3.875
                    4'd3: harm_ratio = 12'd1176;  // 9.1875
                    4'd4: harm_ratio = 12'd2088;  // 16.3125
                    default: harm_ratio = 12'd0;
                endcase
            end
            else if (TIMBRE == 0) begin
                // ---- 钢琴：非谐（拉伸）谐波 f_n = n·f0·sqrt(1+B n²)，B = 3e-4 ----
                case (h)
                    4'd1: harm_ratio = 12'd128;   // 1.0000
                    4'd2: harm_ratio = 12'd256;   // 2.0000
                    4'd3: harm_ratio = 12'd385;   // 3.0078
                    4'd4: harm_ratio = 12'd513;   // 4.0078
                    4'd5: harm_ratio = 12'd642;   // 5.0156
                    default: harm_ratio = 12'd772; // 6.0313
                endcase
            end
            else begin
                case (h)
                    4'd1: harm_ratio = 12'd128;
                    4'd2: harm_ratio = 12'd256;
                    4'd3: harm_ratio = 12'd384;
                    4'd4: harm_ratio = 12'd512;
                    4'd5: harm_ratio = 12'd640;
                    default: harm_ratio = 12'd768;
                endcase
            end
        end
    endfunction
    function [3:0] decay_shift;
        input [3:0] h;
        begin
            if (TIMBRE == 3) begin
                // ---- 马林巴：更短的衰减（"哒"一下就消失）----
                case (h)
                    4'd1: decay_shift = 4'd12;   // τ ≈ 78 ms
                    4'd2: decay_shift = 4'd10;   // τ ≈ 19 ms
                    4'd3: decay_shift = 4'd10;
                    default: decay_shift = 4'd9;  // τ ≈ 10 ms（高次瞬间消失）
                endcase
            end
            else if (TIMBRE == 1) begin
                // ---- 长笛：极慢衰减（s=15 → τ=32768 采样 ≈ 621 ms）----
                //   2 秒只衰约 28 dB，听感接近"持续音"
                decay_shift = 4'd15;
            end
            else begin
                // ---- 钢琴：高次谐波衰得快（音色由亮变暗）----
                case (h)
                    4'd1: decay_shift = 4'd14;
                    4'd2: decay_shift = 4'd13;
                    4'd3: decay_shift = 4'd13;
                    4'd4: decay_shift = 4'd12;
                    4'd5: decay_shift = 4'd12;
                    default: decay_shift = 4'd11;
                endcase
            end
        end
    endfunction

    // ------------------------------------------------------------------
    // 2. 24 路谐波状态：相位 / 包络 / 起音标志
    // ------------------------------------------------------------------
    reg [PHASE_BITS-1:0] phase [0:TOTAL-1];
    reg [15:0]           env   [0:TOTAL-1];
    reg                  atk   [0:TOTAL-1];

    genvar gv, gh;
    generate
        for (gv = 0; gv < VOICE_NUM; gv = gv + 1) begin : gen_voice
            for (gh = 1; gh <= HARM_NUM; gh = gh + 1) begin : gen_harm

                localparam IDX = gv * HARM_NUM + (gh - 1);
                localparam WGT = harm_weight(gh);      // A[h]
                localparam DSC = decay_shift(gh);      // 衰减右移位数
                // 起音步进：钢琴/长笛 64 拍（1.2 ms，瞬间起音）；
//           管风琴 2048 拍（约 38 ms，有"渐强"感）
localparam WST = (TIMBRE == 2) ? (WGT >> 11) : (WGT >> 6);

                localparam RAT = harm_ratio(gh);       // ×128 定点的倍数
                wire [PHASE_BITS-1:0] fcw_v = voice_fcw[gv*PHASE_BITS +: PHASE_BITS];
                // 谐波相位增量 = fcw × (倍率/128)，倍率是常量 → 综合成乘法/移位
                wire [PHASE_BITS+11:0] inc_full = fcw_v * RAT;
                wire [PHASE_BITS-1:0]  inc_v    = inc_full[PHASE_BITS+6:7];

                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        phase[IDX] <= {PHASE_BITS{1'b0}};
                        env[IDX]   <= 16'd0;
                        atk[IDX]   <= 1'b0;
                    end
                    else if (voice_trig[gv]) begin
                        // 敲击：包络从 0 重新起音；相位不清零，
                        // 让同音重复触发时相位保持随机（避免完全同相叠加）
                        env[IDX] <= 16'd0;
                        atk[IDX] <= 1'b1;
                    end
                    else if (sample_req) begin
                        phase[IDX] <= phase[IDX] + inc_v;

                        if (atk[IDX]) begin
                            if (env[IDX] >= WGT) begin
                                env[IDX] <= WGT;
                                atk[IDX] <= 1'b0;
                            end
                            else begin
                                env[IDX] <= env[IDX] + WST;
                            end
                        end
                        else if (env[IDX] == 16'd0) begin
                            // 已静音，保持 0（必须显式判断，否则 0-1 会回绕成 65535）
                        end
                        else if (voice_busy[gv]) begin
                            if (TIMBRE == 2) begin
                                // 管风琴：按住时包络保持（持续音，不衰减）
                            end
                            else begin
                                // 自然衰减：高次谐波掉得快，音色由亮变暗
                                env[IDX] <= env[IDX] - ((env[IDX] >> DSC) | 16'd1);
                            end
                        end
                        else begin
                            // 松键：damper 快速止音（τ ≈ 9.7 ms）
                            env[IDX] <= env[IDX] - ((env[IDX] >> 9) | 16'd1);
                        end
                    end
                end

            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // 3. 32 点正弦表（峰值 32767，有符号）
    // ------------------------------------------------------------------
    function signed [15:0] sin_lut;
        input [5:0] i;              // 0..31 有效，32 视作 0（整周期）
        begin
            case (i[4:0])
                5'd0 : sin_lut =  16'sd0;
                5'd1 : sin_lut =  16'sd6393;
                5'd2 : sin_lut =  16'sd12540;
                5'd3 : sin_lut =  16'sd18205;
                5'd4 : sin_lut =  16'sd23170;
                5'd5 : sin_lut =  16'sd27245;
                5'd6 : sin_lut =  16'sd30274;
                5'd7 : sin_lut =  16'sd32138;
                5'd8 : sin_lut =  16'sd32767;
                5'd9 : sin_lut =  16'sd32138;
                5'd10: sin_lut =  16'sd30274;
                5'd11: sin_lut =  16'sd27245;
                5'd12: sin_lut =  16'sd23170;
                5'd13: sin_lut =  16'sd18205;
                5'd14: sin_lut =  16'sd12540;
                5'd15: sin_lut =  16'sd6393;
                5'd16: sin_lut =  16'sd0;
                5'd17: sin_lut = -16'sd6393;
                5'd18: sin_lut = -16'sd12540;
                5'd19: sin_lut = -16'sd18205;
                5'd20: sin_lut = -16'sd23170;
                5'd21: sin_lut = -16'sd27245;
                5'd22: sin_lut = -16'sd30274;
                5'd23: sin_lut = -16'sd32138;
                5'd24: sin_lut = -16'sd32767;
                5'd25: sin_lut = -16'sd32138;
                5'd26: sin_lut = -16'sd30274;
                5'd27: sin_lut = -16'sd27245;
                5'd28: sin_lut = -16'sd23170;
                5'd29: sin_lut = -16'sd18205;
                5'd30: sin_lut = -16'sd12540;
                default: sin_lut = -16'sd6393;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // 4. 串行扫描：st 0 .. TOTAL+2
    //    st 0..TOTAL-1 : 取第 st 路的相位/包络，算正弦（组合）
    //    st TOTAL..TOTAL+1 : 流水排空
    //    st TOTAL+2        : 输出饱和
    //    ⚠ 2026-10-27 修正：原来把 24（4 声部×6 谐波）写死了。
    //      VOICE_NUM=1 时 TOTAL=6，若仍按 st 2..25 累加，
    //      第 6..23 拍会重复读 phase[0] 并累加 → 基波被算 21 次。
    //      改为随 TOTAL 伸缩的常量，4 声部时数值与原来完全一致。
    // ------------------------------------------------------------------
    localparam [4:0] ST_END  = TOTAL + 3;      // 扫描结束值（含）
    localparam [4:0] ST_ACCL = TOTAL + 1;      // 最后一个累加拍
    localparam [4:0] ST_OUT  = TOTAL + 2;      // 输出拍

    reg [4:0] st;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          st <= 5'd0;
        else if (sample_req) st <= 5'd0;
        else if (st < ST_END) st <= st + 5'd1;
    end

    wire [4:0] st_idx = (st < TOTAL) ? st : 5'd0;      // 排除越界读

    wire [PHASE_BITS-1:0] ph_cur = phase[st_idx];
    wire [15:0]           ev_cur = env[st_idx];

    // ---- 正弦插值：s = s0 + (s1-s0)*frac/16 ----
    wire [4:0]         sidx = ph_cur[PHASE_BITS-1 -: 5];
    wire [3:0]         sfr  = ph_cur[PHASE_BITS-6 -: 4];
    wire signed [15:0] s0   = sin_lut({1'b0, sidx});
    wire signed [15:0] s1   = sin_lut({1'b0, sidx} + 6'd1);
    wire signed [16:0] dsin = $signed(s1) - $signed(s0);
    wire signed [20:0] dval = dsin * $signed({1'b0, sfr});
    wire signed [15:0] sval = $signed(s0) + dval[19:4];   // >>4

    // ---- 三级流水：正弦 → 乘包络 → 累加 ----
    reg signed [15:0] s_d;
    reg        [15:0] e_d;
    reg signed [31:0] prod;
    reg signed [23:0] acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_d  <= 16'sd0;
            e_d  <= 16'd0;
            prod <= 32'sd0;
            acc  <= 24'sd0;
        end
        else if (sample_req) begin
            acc  <= 24'sd0;                 // 新的一帧，累加器清零
        end
        else begin
            // stage 1：寄存当前路的正弦与包络
            s_d  <= sval;
            e_d  <= ev_cur;
            // stage 2：电平乘包络（16×17 → 综合到 DSP）
            prod <= s_d * $signed({1'b0, e_d});
            // stage 3：累加（st 2..25 恰好覆盖 24 路）
            if ((st >= 5'd2) && (st <= ST_ACCL))
                acc <= acc + {{8{prod[31]}}, prod[31:16]};
        end
    end

    // ------------------------------------------------------------------
    // 5. 输出：×0.875（= acc - acc/8）+ 饱和
    //    2026-10-27 上板反馈"声音太小"：÷4 → ÷2 后仍嫌小，
    //    再提到 ~50% 满量程（单声部实测约 17600）。
    //    ⚠ 已知取舍：单音 54%、4 音和弦会超过 16 位上限而被饱和（削波）。
    //      单音与和弦本来差约 3 倍，线性增益无法两全。
    //      若日后要"都响且都不削波"，需要加动态限幅（压缩器），不是继续改这里。
    // ------------------------------------------------------------------
    wire signed [23:0] mix = acc - (acc >>> 3);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            audio <= 16'sd0;
        end
        else if (st == ST_OUT) begin
            if (mix > 24'sd32767)
                audio <= 16'sd32767;
            else if (mix < -24'sd32768)
                audio <= 16'sh8000;          // -32768
            else
                audio <= mix[15:0];
        end
    end

endmodule
