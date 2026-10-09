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
//  2) 事件锁存：note_on 跳变可能发生在任意时刻，而包络每 sample_en
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
    input  wire                  note_on,     // 1 = 按下 / 0 = 松开
    input  wire                  gate,        // 1 = 该声部正在发声
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

    wire trig_edge =  note_on & ~note_on_d;
    wire rel_edge  = ~note_on &  note_on_d;

    // ------------------------------------------------------------------
    // 事件锁存
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            note_on_d    <= 1'b0;
            trig_pending <= 1'b0;
            rel_pending  <= 1'b0;
        end
        else begin
            note_on_d <= note_on;

            if (trig_edge)          trig_pending <= 1'b1;
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

                // ---------- 持续：电平保持 ----------
                S_SUSTAIN: begin
                    env <= SUS_LEVEL;
                    if (rel_pending || !gate) state <= S_RELEASE;
                end

                // ---------- 释放：衰减到 0 ----------
                S_RELEASE: begin
                    if (trig_pending) begin
                        state <= S_ATTACK;         // 余韵中重按
                    end
                    else if (env <= REL_STEP) begin
                        env   <= {ENV_BITS{1'b0}};
                        state <= S_IDLE;
                    end
                    else begin
                        env <= env - REL_STEP;
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
