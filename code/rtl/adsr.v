// ============================================================================
//  模块名  : adsr.v
//  功能    : ADSR 包络发生器 —— Attack / Decay / Sustain / Release
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)
//
//  ── 为什么需要包络 ────────────────────────────────────────────────
//  没有包络的声音是"硬切"的：按键瞬间满音量，松开瞬间静音。
//  真实乐器都有起音和余韵，ADSR 就是模拟这个过程的最小模型。
//
//  ── 四个阶段 ──────────────────────────────────────────────────────
//    ① ATTACK  ：0 → 最大（线性递增，每采样周期 +ATK_STEP）
//    ② DECAY   ：最大 → SUS_LEVEL
//    ③ SUSTAIN ：保持在 SUS_LEVEL
//    ④ RELEASE ：SUS_LEVEL → 0
//
//  ── 实现要点 ──────────────────────────────────────────────────────
//  1) 线性递增/递减，用整数加减，**彻底避开位宽与饱和的坑**
//     （早期版本用移位乘法逼近指数曲线，因位宽截断导致 env 跳变）
//  2) 事件锁存：note_on / trig 跳变可能发生在任意时刻，而包络每 sample_en
//     才更新一次。用 trig_pending / rel_pending 锁存事件，避免漏掉。
//     这与 note_alloc 处理 note_valid 的思路一致。
//  3) env 只在 sample_en 时更新，与整个音频通路保持同一节拍。
//
//  作者    : 第二代迭代 2
// ============================================================================
module adsr #(
    parameter ENV_BITS  = 8,          // 包络位宽（0~255）
    parameter SUS_LEVEL = 8'd128,     // 持续电平
    parameter ATK_STEP  = 8'd4,       // Attack 每周期步进（越大越快）
    parameter DEC_STEP  = 8'd2,       // Decay 每周期步进
    parameter REL_STEP  = 8'd2        // Release 每周期步进
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  sample_en,   // 音频采样使能
    input  wire                  trig,        // note-on 单周期脉冲（抢占/重按也会来）
    input  wire                  note_on,     // 电平：1 = 按住 / 0 = 松开
    input  wire                  gate,        // 1 = 该声部正在发声
    input  wire                  fast_release,// 1 = 松键立即静音（渐弱开关关）
    output reg  [ENV_BITS-1:0]   env          // 包络电平 0~255
);

    localparam S_IDLE    = 3'd0;
    localparam S_ATTACK  = 3'd1;
    localparam S_DECAY   = 3'd2;
    localparam S_SUSTAIN = 3'd3;
    localparam S_RELEASE = 3'd4;

    localparam [ENV_BITS-1:0] ENV_MAX = {ENV_BITS{1'b1}};   // 255

    reg [2:0] state;

    reg note_on_d;
    reg trig_pending;
    reg rel_pending;

    wire rel_edge  = ~note_on &  note_on_d;

    // ------------------------------------------------------------------
    // 2026-11-04 衰减节拍
    //
    // 原来是"SUSTAIN 恒定 160 + RELEASE 每周期减 3"，结果是：
    //   按住时音量完全不变（三角/方波听起来像风琴，永远不弱）；
    //   松键后约 1 ms 就归零（听感是"硬切"，不是渐弱）。
    // 现在改用两个慢节拍做线性衰减：
    //   按住 每 512 采样减 1 → 160 级约 1.55 s 落到底（像钢琴那样慢慢弱下去）
    //   松键 每 16  采样减 1 → 约 48 ms 收尾（止音手感）
    // ------------------------------------------------------------------
    reg [8:0] dec_phase;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)             dec_phase <= 9'd0;
        else if (sample_en)     dec_phase <= dec_phase + 9'd1;
    end
    wire sus_dec = (dec_phase == 9'd191);      // 每 192 采样（160 级约 0.58 s）
    wire rel_dec = (dec_phase[3:0] == 4'hF);   // 每 16 采样

    // ------------------------------------------------------------------
    // 事件锁存
    //
    // 为什么要单独的 trig 端口（2026-10-18 修正）：
    //   原来 trig_edge = note_on & ~note_on_d，靠 note_on 的上升沿起音。
    //   但 synth_top 里 note_on 接的是 voice_trig | voice_busy ——
    //   抢占（4 声部占满时按第 5 个键）时 voice_busy 一直是 1，
    //   voice_trig 只在单拍脉冲，note_on 根本没有上升沿 →
    //   包络不重新起音，新音"没有音头"。
    //   现在直接接收 note-on 脉冲，抢占与重复按键都能正确起音。
    //   note_on 电平只用来检测"松开"（下降沿 → RELEASE）。
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            note_on_d    <= 1'b0;
            trig_pending <= 1'b0;
            rel_pending  <= 1'b0;
        end
        else begin
            note_on_d <= note_on;

            if (trig)               trig_pending <= 1'b1;
            else if (sample_en)     trig_pending <= 1'b0;

            if (rel_edge)           rel_pending <= 1'b1;
            else if (sample_en)     rel_pending <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // 状态机 + 包络更新（单一 always 块，避免多驱动）
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            env   <= {ENV_BITS{1'b0}};
        end
        else if (sample_en) begin
            case (state)
                // ---------- 空闲：等按下 ----------
                S_IDLE: begin
                    env <= {ENV_BITS{1'b0}};
                    if (trig_pending) state <= S_ATTACK;
                end

                // ---------- 起音：线性递增到满 ----------
                S_ATTACK: begin
                    if (rel_pending) begin
                        state <= S_RELEASE;
                    end
                    else if (env >= (ENV_MAX - ATK_STEP)) begin
                        env   <= ENV_MAX;
                        state <= S_DECAY;          // 到达峰值，转入衰减
                    end
                    else begin
                        env <= env + ATK_STEP;
                    end
                end

                // ---------- 衰减：下降到持续电平 ----------
                S_DECAY: begin
                    if (rel_pending) begin
                        state <= S_RELEASE;
                    end
                    else if (env <= (SUS_LEVEL + DEC_STEP)) begin
                        env   <= SUS_LEVEL;
                        state <= S_SUSTAIN;        // 到达持续电平
                    end
                    else begin
                        env <= env - DEC_STEP;
                    end
                end

                // ---------- 持续：缓慢衰减（钢琴式渐弱） ----------
                S_SUSTAIN: begin
                    // 数字波形（三角/方波/锯齿/脉冲）：按住就一直保持满音量，
                    // 只有松键才进入 RELEASE —— 这是风琴/合成器类音色的正确行为。
                    // 钢琴/吉他不走这条 ADSR 通路（它们用 KS 引擎自然衰减）。
                    env <= SUS_LEVEL;
                    if (rel_pending || !gate) begin
                        state <= S_RELEASE;
                    end
                end

                // ---------- 释放：渐弱(48ms) 或 立即消失（由 fast_release 决定） ----------
                S_RELEASE: begin
                    if (trig_pending) begin
                        state <= S_ATTACK;         // 余韵中重按
                    end
                    else if (fast_release) begin
                        env   <= {ENV_BITS{1'b0}}; // 直接静音
                        state <= S_IDLE;
                    end
                    else if (rel_dec) begin
                        if (env <= 8'd1) begin
                            env   <= {ENV_BITS{1'b0}};
                            state <= S_IDLE;
                        end
                        else begin
                            env <= env - 8'd1;
                        end
                    end
                end

                default: begin
                    state <= S_IDLE;
                    env   <= {ENV_BITS{1'b0}};
                end
            endcase
        end
    end

endmodule
