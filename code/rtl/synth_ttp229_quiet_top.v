// ============================================================================
//  module : synth_ttp229_quiet_top.v
//  purpose: same as synth_ttp229 (touch / latency / UART all live) but the
//           audio output is held at digital zero, so the speaker stays silent.
//
//  why: bench work and UI bring-up must not make noise. Everything except the
//       DAC data path is the real implementation - touch scan, IR gesture,
//       latency meter, 576-byte UART frames all behave exactly as in
//       synth_ttp229_top, so the web UI sees real data.
//
//  I2S clocks are still driven on purpose: PCM5102A needs a valid clock to sit
//  at its mid-rail output. With the DAC data stuck at 0 and pa_en low, both the
//  external PAM8403 branch and the on-board MAX98357A are quiet.
//
//  To get sound back: program the normal synth_ttp229 target.
// ============================================================================
`timescale 1ns / 1ps

module synth_ttp229_quiet_top (
    input  wire        clk,        // 27 MHz, pin 4
    input  wire        ir_in,      // IR obstacle module, pin 74
    output wire        ttp_scl,    // -> TTP229 SCL, pin 75
    input  wire        ttp_sdo,    // <- TTP229 SDO, pin 76
    input  wire        uart_rx_i,  // <- USB-TTL TXD, pin 27
    output wire        i2s_bck,    // pin 56
    output wire        i2s_lrck,   // pin 55
    output wire        i2s_din,    // pin 54
    output wire        pa_en,      // pin 51 (on-board MAX98357A enable)
    output wire [4:0]  uart_tx,    // 48/69/42/77/79
    output wire [5:0]  led         // pins 15..20, active low
);

    wire core_bck, core_lrck, core_din, core_pa;

    synth_ttp229_top u_core (
        .clk       (clk),
        .ir_in     (ir_in),
        .ttp_scl   (ttp_scl),
        .ttp_sdo   (ttp_sdo),
        .uart_rx_i (uart_rx_i),
        .i2s_bck   (core_bck),
        .i2s_lrck  (core_lrck),
        .i2s_din   (core_din),
        .pa_en     (core_pa),
        .uart_tx   (uart_tx),
        .led       (led)
    );

    // Keep the clocks, mute the data, shut the on-board amp.
    assign i2s_bck  = core_bck;
    assign i2s_lrck = core_lrck;
    assign i2s_din  = 1'b0;
    assign pa_en    = 1'b0;

    // core_din / core_pa are intentionally unused: the synthesiser still runs
    // and its samples still go out over UART, they just never reach the DAC.
endmodule
