// ============================================================================
//  模块名  : i2s_tx.v   （v2 · 标准 Philips I2S，重写）
//  功能    : 把并行音频样本按 I2S 协议串行输出给外部 DAC（如 PCM5102A）
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，主时钟 27 MHz
//
//  ── 为什么要重写（v1 的两个真问题）────────────────────────────────
//  v1 是"左对齐"时序，不是 I2S：
//    · LRCK 一跳变，MSB 立刻输出 → 没有 I2S 规定的 1 个 BCK 延迟位
//    · PCM5102A 模块基本都硬接成 I2S 模式，收到左对齐会左右声道错位/声音发闷
//  v1 每个声道只有 16 个 BCK（32 BCK/LRCK）：
//    · 采样率被顶到 105 kHz，不是标准音频速率
//  本版：每声道 32 BCK（64 BCK/LRCK），1 位延迟 + 16 位数据 + 15 位补零。
//
//  ── 时序图（标准 Philips I2S，16bit 数据 / 32bit 帧）──────────────
//       LRCK  ________|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|________
//       BCK   _/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\_
//       DIN   X  D15 D14 ... D0  0 0 0 ... 0  X  D15 ... D0  0...
//             ↑  ↑                            ↑
//         LRCK跳变  ↑                      LRCK跳变
//             第1个BCK上升沿 = 无效位（I2S 规定）
//                 第2个BCK上升沿起 = D15..D0（MSB first）
//
//  ── 本设计的采样率（Tang Nano 20K 27MHz）─────────────────────────
//      BCK_HALF = 4  →  BCK = 27MHz / (2×4)  = 3.375 MHz
//                    →  fs  = 3.375M / 64    = 52734.375 Hz
//      ⚠ 不是 48000！所有 FCW 必须用 52734.375 算（见 tools/gen_fcw.py）
//      改 BCK_HALF 可换速率：5 → 42187.5 Hz，3 → 70312.5 Hz
//
//  ── 用法 ────────────────────────────────────────────────────────
//      sample_req 每个音频帧拉高 1 个 clk 周期，此时更新 sample_l/r 即可。
//      模块内部会在帧起点把样本锁存进 l_reg/r_reg，发送途中不会被上游改写。
// ============================================================================
module i2s_tx #(
    parameter DATA_BITS = 16,    // 样本位宽（16/24/32；本工程用 16）
    parameter BCK_HALF  = 4      // BCK 半周期 = BCK_HALF 个 clk 周期
)(
    input  wire                 clk,         // 主时钟（27 MHz）
    input  wire                 rst_n,       // 低电平复位
    input  wire [DATA_BITS-1:0] sample_l,    // 左声道样本（有符号，二进制补码）
    input  wire [DATA_BITS-1:0] sample_r,    // 右声道样本
    output reg                  bck,         // 位时钟
    output reg                  lrck,        // 声道时钟（0=左，1=右）
    output reg                  din,         // 串行数据（MSB first）
    output reg                  sample_req   // 每帧拉高 1 clk，请求下一组样本
);

    // 帧结构常数（bit_cnt 0..63）
    localparam [5:0] SLOT_HALF = 6'd32;                  // 每声道 32 个 BCK
    localparam [5:0] LOAD_L    = 6'd1;                   // 左声道 MSB（延迟 1 位）
    localparam [5:0] END_L     = LOAD_L + DATA_BITS - 1; // 左声道 LSB
    localparam [5:0] LOAD_R    = SLOT_HALF + 6'd1;       // 右声道 MSB
    localparam [5:0] END_R     = LOAD_R + DATA_BITS - 1; // 右声道 LSB

    // ------------------------------------------------------------------
    // 1. BCK 生成：每 BCK_HALF 个 clk 翻转一次
    // ------------------------------------------------------------------
    reg [7:0] bck_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bck_cnt <= 8'd0;
            bck     <= 1'b0;
        end
        else if (bck_cnt >= (BCK_HALF - 1)) begin
            bck_cnt <= 8'd0;
            bck     <= ~bck;
        end
        else begin
            bck_cnt <= bck_cnt + 8'd1;
        end
    end

    // BCK 下降沿检测（所有数据变化都发生在下降沿）
    reg bck_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) bck_d <= 1'b0;
        else        bck_d <= bck;
    end
    wire bck_fall = bck_d & ~bck;

    // ------------------------------------------------------------------
    // 2. 位计数器：0 ~ 63（一个 LRCK 周期 = 64 个 BCK）
    // ------------------------------------------------------------------
    reg [5:0] bit_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt <= 6'd0;
        end
        else if (bck_fall) begin
            bit_cnt <= (bit_cnt == 6'd63) ? 6'd0 : (bit_cnt + 6'd1);
        end
    end

    // ------------------------------------------------------------------
    // 3. LRCK：bit_cnt 0..31 = 左声道(0)，32..63 = 右声道(1)
    //    在下降沿更新，与 I2S 规范一致
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lrck <= 1'b0;
        end
        else if (bck_fall) begin
            lrck <= (bit_cnt >= SLOT_HALF) ? 1'b1 : 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // 4. 样本锁存：帧起点（bit_cnt==0）打一拍，保证发送期间数据不变
    // ------------------------------------------------------------------
    reg [DATA_BITS-1:0] l_reg, r_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l_reg <= {DATA_BITS{1'b0}};
            r_reg <= {DATA_BITS{1'b0}};
        end
        else if (bck_fall && (bit_cnt == 6'd0)) begin
            l_reg <= sample_l;
            r_reg <= sample_r;
        end
    end

    // ------------------------------------------------------------------
    // 5. 移位输出
    //    load_*  : 输出 MSB
    //    sh_*    : 输出后续位
    //    其余    : 输出 0（延迟位 + 补零位）
    // ------------------------------------------------------------------
    reg [DATA_BITS-1:0] shift_reg;

    wire load_l = bck_fall && (bit_cnt == LOAD_L);
    wire load_r = bck_fall && (bit_cnt == LOAD_R);
    wire sh_l   = bck_fall && (bit_cnt > LOAD_L) && (bit_cnt <= END_L);
    wire sh_r   = bck_fall && (bit_cnt > LOAD_R) && (bit_cnt <= END_R);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg <= {DATA_BITS{1'b0}};
            din       <= 1'b0;
        end
        else if (load_l) begin
            shift_reg <= {l_reg[DATA_BITS-2:0], 1'b0};
            din       <= l_reg[DATA_BITS-1];
        end
        else if (load_r) begin
            shift_reg <= {r_reg[DATA_BITS-2:0], 1'b0};
            din       <= r_reg[DATA_BITS-1];
        end
        else if (sh_l || sh_r) begin
            din       <= shift_reg[DATA_BITS-1];
            shift_reg <= {shift_reg[DATA_BITS-2:0], 1'b0};
        end
        else if (bck_fall) begin
            din       <= 1'b0;      // 延迟位 + 尾部补零
        end
    end

    // ------------------------------------------------------------------
    // 6. 样本请求：右声道发完（bit_cnt==48）就提前 16 个 BCK 要下一帧
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sample_req <= 1'b0;
        else        sample_req <= bck_fall && (bit_cnt == END_R);
    end

endmodule
