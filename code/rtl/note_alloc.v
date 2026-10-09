// ============================================================================
//  模块名  : note_alloc.v
//  功能    : 音符分配器 —— 管理 note-on / note-off，把音符分配到空闲声部
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)
//
//  ── 为什么需要它 ──────────────────────────────────────────────────
//  复音合成器有 N 个声部，但按键是随时按下/松开的。
//  必须有一套仲裁逻辑回答两个问题：
//    1. 新按下的音符，分给哪个声部？
//    2. 松开的音符，怎么释放它占用的声部？
//
//  ── 分配策略 ──────────────────────────────────────────────────────
//  优先级从高到低：
//    ① 该音符已经在这个声部上 → 复用（重复按键不占新声部）
//    ② 完全空闲的声部       → 分配，从 0 号开始找
//    ③ 全部占满             → 抢占"最早分配"的声部（防止卡音）
//
//  ── 关于声部年龄计数器 ────────────────────────────────────────────
//  voice_age[i] 在每个时钟周期递增（只对忙碌声部计数）。
//  抢占时选 voice_age 最大的声部 —— 它是最早被分配的，
//  抢占它对听感的破坏最小。
//
//  作者    : 第二代迭代 2
// ============================================================================
module note_alloc #(
    parameter VOICE_NUM = 4,
    parameter NOTE_BITS = 5        // 音符索引位宽（0~24 需 5 位）
)(
    input  wire                     clk,
    input  wire                     rst_n,
    // ---- 音符事件（来自按键/触摸模块）----
    input  wire                     note_valid,   // 事件有效
    input  wire                     note_on,      // 1=按下 0=松开
    input  wire [NOTE_BITS-1:0]     note_idx,     // 音符索引
    // ---- 声部状态输出 ----
    output reg  [VOICE_NUM-1:0]     voice_busy,   // 1 = 该声部正在发声
    output reg  [VOICE_NUM*NOTE_BITS-1:0] voice_note, // 各声部当前音符
    output reg  [VOICE_NUM-1:0]     voice_trig    // 分配瞬间的单周期脉冲
);

    // ------------------------------------------------------------------
    // 1. 声部年龄计数器：用于"抢占最早的"
    // ------------------------------------------------------------------
    reg [31:0] voice_age [0:VOICE_NUM-1];

    // ------------------------------------------------------------------
    // 2. 事件解码：把一次按键事件拆成"按下集合"与"松开集合"
    //    match_on[i]  = 1 表示声部 i 正在演奏被松开的那个音符
    //    match_hold[i]= 1 表示声部 i 正在演奏被重复按下的音符
    // ------------------------------------------------------------------
    wire [VOICE_NUM-1:0] match_on;
    wire [VOICE_NUM-1:0] match_hold;
    wire [VOICE_NUM-1:0] voice_free;

    genvar i;
    generate
        for (i = 0; i < VOICE_NUM; i = i + 1) begin : gen_match
            assign match_on  [i] = voice_busy[i] &&
                                   voice_note[i*NOTE_BITS +: NOTE_BITS] == note_idx;
            assign match_hold[i] = match_on[i];
            assign voice_free[i] = ~voice_busy[i];
        end
    endgenerate

    // ------------------------------------------------------------------
    // 3. 组合查找：空闲声部号 / 最早声部号
    //    （用循环扫描，综合器会展开成并行比较，不是真的跑循环）
    // ------------------------------------------------------------------
    integer k;

    reg              found_free;
    reg [7:0]        free_no;
    reg              found_oldest;
    reg [7:0]        oldest_no;

    always @(*) begin
        // ---- 找第一个空闲声部 ----
        found_free = 1'b0;
        free_no    = 8'd0;
        for (k = 0; k < VOICE_NUM; k = k + 1) begin
            if (!found_free && voice_free[k]) begin
                found_free = 1'b1;
                free_no    = k[7:0];
            end
        end

        // ---- 找年龄最大的声部（最早分配）----
        found_oldest = 1'b0;
        oldest_no    = 8'd0;
        begin : find_oldest
            reg [31:0] max_age;
            integer    j;
            max_age = 32'd0;
            for (j = 0; j < VOICE_NUM; j = j + 1) begin
                if (voice_busy[j] && (voice_age[j] >= max_age)) begin
                    max_age      = voice_age[j];
                    oldest_no    = j[7:0];
                    found_oldest = 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // 4. 主状态机：分配 / 释放
    // ------------------------------------------------------------------
    integer v, w;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            voice_busy <= {VOICE_NUM{1'b0}};
            voice_note <= {(VOICE_NUM*NOTE_BITS){1'b0}};
            voice_trig <= {VOICE_NUM{1'b0}};
            for (v = 0; v < VOICE_NUM; v = v + 1) begin
                voice_age[v] <= 32'd0;
            end
        end
        else begin
            // ---- 默认：清除触发脉冲 ----
            voice_trig <= {VOICE_NUM{1'b0}};

            // ---- 年龄递增（忙碌声部才加）----
            for (v = 0; v < VOICE_NUM; v = v + 1) begin
                if (voice_busy[v]) begin
                    voice_age[v] <= voice_age[v] + 32'd1;
                end
                else begin
                    voice_age[v] <= 32'd0;
                end
            end

            // ---- 处理音符事件 ----
            if (note_valid) begin
                if (note_on) begin
                    // ============ 按下 ============
                    // 优先复用：该音符已在某个声部上
                    if (|match_hold) begin
                        for (w = 0; w < VOICE_NUM; w = w + 1) begin
                            if (match_hold[w]) begin
                                voice_age[w] <= 32'd0;   // 重置年龄，视作新音符
                                voice_trig[w] <= 1'b1;
                            end
                        end
                    end
                    // 其次找空闲声部
                    else if (found_free) begin
                        voice_busy[free_no] <= 1'b1;
                        voice_note[free_no*NOTE_BITS +: NOTE_BITS] <= note_idx;
                        voice_age [free_no] <= 32'd0;
                        voice_trig[free_no] <= 1'b1;
                    end
                    // 最后抢占最早的
                    else if (found_oldest) begin
                        voice_note[oldest_no*NOTE_BITS +: NOTE_BITS] <= note_idx;
                        voice_age [oldest_no] <= 32'd0;
                        voice_trig[oldest_no] <= 1'b1;
                    end
                end
                else begin
                    // ============ 松开 ============
                    for (w = 0; w < VOICE_NUM; w = w + 1) begin
                        if (match_on[w]) begin
                            voice_busy[w] <= 1'b0;
                            voice_age [w] <= 32'd0;
                        end
                    end
                end
            end
        end
    end

endmodule
