// ============================================================================
//  模块名  : self_test_12notes.v
//  功能    : 最小实现自检 —— 零接线循环播放钢琴十二平均律（C4~B4）
//  板卡    : Sipeed Tang Nano 20K (GW2AR-18)，27 MHz
//
//  ── 用途 ──────────────────────────────────────────────────────────
//  板上只留有 USB 供电线和喇叭时使用：
//      · 不需要任何按键/触摸模块（状态机自动产生音符事件）
//      · 一次烧录即可听完 12 个半音，验证音高、音色与音量
//  这也是播放"真实硬件"与"数字 WAV"对比的基准固件。
//
//  ── 播放序列 ──────────────────────────────────────────────────────
//      C4 → C#4 → D4 → D#4 → E4 → F4 → F#4 → G4 → G#4 → A4 → A#4 → B4
//      每个音：按住 0.6 s → 松开 0.3 s（让制音器自然收尾）→ 下一个
//      一轮约 10.8 s，之后无限循环
//
//  ── 音量（数字化计算）─────────────────────────────────────────────
//      piano_engine 单声部输出峰值约 17985（54.9% 满量程）
//      本模块再乘 15/16（raw - raw/16）→ 约 16861 ≈ 51.5%
//      即目标"50% 左右"，既不浪费动态范围，也给和弦留了余量
//
//  ── 与 synth_top 的区别 ──────────────────────────────────────────
//      这里不用 note_alloc / mix_tree（单声部顺序播放用不上），
//      直接：状态机 → note_table → piano_engine(VOICE_NUM=1) → 缩放 → i2s_tx
//      资源远小于完整 12 键版，适合做 bring-up 基准。
// ============================================================================
`timescale 1ns / 1ps

module self_test_12notes #(
    parameter BCK_HALF  = 4,            // fs = 27MHz/8/64 = 52734.375 Hz
    parameter HOLD_CLK  = 32'd16_200_000,  // 0.60 s @27MHz
    parameter GAP_CLK   = 32'd8_100_000,   // 0.30 s @27MHz
    parameter NOTE_NUM  = 12
)(
    input  wire        clk,
    output wire        i2s_bck,
    output wire        i2s_lrck,
    output wire        i2s_din,
    output wire        pa_en,
    output wire [5:0]  led
);

    // ==================================================================
    // 1. 上电复位（不依赖外部按键）
    // ==================================================================
    reg [15:0] por_cnt = 16'd0;
    reg        rst_n   = 1'b0;

    always @(posedge clk) begin
        if (&por_cnt) rst_n <= 1'b1;
        else          por_cnt <= por_cnt + 16'd1;
    end

    // ==================================================================
    // 2. 播放状态机：IDLE(起音) → HOLD(按住) → GAP(松开)
    // ==================================================================
    localparam S_IDLE = 2'd0;
    localparam S_HOLD = 2'd1;
    localparam S_GAP  = 2'd2;

    reg [1:0]  state;
    reg [3:0]  note_i;          // 0..11 → C4..B4
    reg [31:0] cnt;
    reg        note_valid;      // 单周期事件脉冲
    reg        note_on;         // 1=按下 0=松开
    reg        gate;            // 1=声部持续发声

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            note_i     <= 4'd0;
            cnt        <= 32'd0;
            note_valid <= 1'b0;
            note_on    <= 1'b0;
            gate       <= 1'b0;
        end
        else begin
            note_valid <= 1'b0;         // 默认无事件

            case (state)
                // ---- 起音：发一个 note-on 事件 ----
                S_IDLE: begin
                    note_valid <= 1'b1;
                    note_on    <= 1'b1;
                    gate       <= 1'b1;
                    cnt        <= 32'd0;
                    state      <= S_HOLD;
                end

                // ---- 按住 ----
                S_HOLD: begin
                    cnt <= cnt + 32'd1;
                    if (cnt >= HOLD_CLK) begin
                        note_valid <= 1'b1;
                        note_on    <= 1'b0;   // 松键 → 制音器
                        gate       <= 1'b0;
                        cnt        <= 32'd0;
                        state      <= S_GAP;
                    end
                end

                // ---- 间隔，然后下一个音 ----
                S_GAP: begin
                    cnt <= cnt + 32'd1;
                    if (cnt >= GAP_CLK) begin
                        note_i <= (note_i == (NOTE_NUM - 1)) ? 4'd0 : (note_i + 4'd1);
                        state  <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ==================================================================
    // 3. 音符 → 频率控制字
    // ==================================================================
    wire [31:0] fcw;

    note_table u_note (
        .note_idx ({1'b0, note_i}),     // note_i 是 4 位（0..11），note_idx 要 5 位
        .fcw      (fcw)
    );

    // ==================================================================
    // 4. 钢琴引擎（单声部，6 次谐波）
    // ==================================================================
    wire               sample_req;
    wire signed [15:0] raw_audio;
    wire [0:0]         voice_trig = note_valid & note_on;
    wire [0:0]         voice_busy = gate;

    piano_engine #(
        .VOICE_NUM  (1),
        .HARM_NUM   (6),
        .PHASE_BITS (32)
    ) u_piano (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_req (sample_req),
        .voice_fcw  (fcw),
        .voice_trig (voice_trig),
        .voice_busy (voice_busy),
        .audio      (raw_audio)
    );

    // ==================================================================
    // 5. 音量缩放：×15/16 → 约 51.5% 满量程（目标"50% 左右"）
    //    raw 峰值 17985 → 缩放后约 16861
    // ==================================================================
    wire signed [16:0] scaled = $signed(raw_audio) - ($signed(raw_audio) >>> 4);
    wire signed [15:0] audio  = scaled[15:0];

    // ==================================================================
    // 6. I2S 发送
    // ==================================================================
    i2s_tx #(
        .DATA_BITS (16),
        .BCK_HALF  (BCK_HALF)
    ) u_i2s (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_l   (audio),
        .sample_r   (audio),
        .bck        (i2s_bck),
        .lrck       (i2s_lrck),
        .din        (i2s_din),
        .sample_req (sample_req)
    );

    // ==================================================================
    // 7. 功放使能：最小自检时**常开**
    //
    //    ⚠ 2026-10-27 修正：这里原来沿用了 12 键版的"有音符才开、静音 155ms 关"
    //    门控。但本固件每个音之间只有 0.3 s 间隔 > 155 ms，导致功放在每个音
    //    开头都要从 shutdown 重新唤醒 —— MAX98357A 唤醒约 10~20 ms，期间输出
    //    被切断并伴随 POP，听感就是"音头没了 + 咔哒声 + 严重失真"。
    //    自检固件不需要省电，直接常开。
    // ==================================================================
    assign pa_en = 1'b1;

    // ==================================================================
    // 8. LED 指示（低电平点亮）
    //    led[0] 心跳 1.6 Hz
    //    led[1] 正在发声
    //    led[5:2] 当前音符序号（二进制，0..11）
    // ==================================================================
    reg [23:0] blink;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) blink <= 24'd0;
        else        blink <= blink + 24'd1;
    end

    wire [5:0] led_on = { note_i, gate, blink[23] };

    assign led = ~led_on;

endmodule
