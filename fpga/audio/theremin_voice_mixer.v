`timescale 1ns/1ps
`default_nettype none
// One continuous DDS voice; audio_core routes the mix through a shared AGC
// before loop recording/reverb. Gain and mix remain bounded convex weights.
// Q16 controls are clamped to unity. Full-scale slews take 512 audio frames
// (10.67 ms at 48 kHz); the phase never resets on control changes or mute.
// A single signed 22 x 18 multiplier is reused over the eight-cycle pipeline.
module theremin_voice_mixer #(
    parameter SINE_FILE = "sine_quarter.mem"
)(
    input wire clk, rst_n, sample_ce,
    input wire [31:0] phase_step,
    input wire [16:0] target_gain, target_mix,
    input wire in_valid,
    input wire signed [20:0] in_sample,
    output reg out_valid,
    output reg signed [20:0] out_sample,
    output wire [16:0] actual_gain,actual_mix,
    output wire busy,
    output reg overrun
);
    wire signed [15:0] sine_q;
    reg [31:0] phase;
    reg [16:0] gain_ramp, mix_ramp, gain_hold, mix_hold;
    reg signed [20:0] dry_hold, voice_hold;
    reg signed [21:0] multiply_a;
    reg signed [17:0] multiply_b;
    reg signed [39:0] product, dry_product;
    reg signed [40:0] sum_q16;
    reg [3:0] state;
    wire [16:0] gain_limit = target_gain > 17'd65536 ? 17'd65536 : target_gain;
    wire [16:0] mix_limit = target_mix > 17'd65536 ? 17'd65536 : target_mix;
    assign actual_gain=gain_ramp;assign actual_mix=mix_ramp;
    assign busy = state != 0;
    sine_quarter #(.FILE(SINE_FILE)) u_sine(.clk(clk),.enable(in_valid && !busy),.address(phase[31:21]),.sample(sine_q));

    function [16:0] slew;
        input [16:0] current, target;
        begin
            if (current < target)
                slew = target-current > 17'd128 ? current+17'd128 : target;
            else
                slew = current-target > 17'd128 ? current-17'd128 : target;
        end
    endfunction
    function signed [20:0] saturate;
        input signed [40:0] value_q16;
        reg signed [40:0] value;
        begin
            value = value_q16 >>> 16;
            if (value > 41'sd1048575) saturate = 21'sh0fffff;
            else if (value < -41'sd1048576) saturate = 21'sh100000;
            else saturate = value[20:0];
        end
    endfunction
    // Clocked ROM without a reset preserves block-ROM inference. Read the
    // phase belonging to this input frame, including any prior sample_ce.
    always @(posedge clk) begin
        product <= multiply_a * multiply_b;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase<=0; gain_ramp<=0; mix_ramp<=0; gain_hold<=0; mix_hold<=0;
            dry_hold<=0; voice_hold<=0; multiply_a<=0; multiply_b<=0;
            dry_product<=0; sum_q16<=0; state<=0; out_valid<=0;
            out_sample<=0; overrun<=0;
        end else begin
            out_valid <= 0;
            if (sample_ce) begin
                phase <= phase + phase_step;
                gain_ramp <= slew(gain_ramp, gain_limit);
                mix_ramp <= slew(mix_ramp, mix_limit);
            end
            if (in_valid && busy) overrun<=1;
            case (state)
                0: if (in_valid) begin
                    dry_hold<=in_sample; gain_hold<=gain_ramp;
                    mix_hold<=mix_ramp; state<=1;
                end
                1: begin
                    multiply_a <= $signed({sine_q, 5'b00000});
                    multiply_b <= $signed({1'b0, gain_hold}); state<=2;
                end
                2: state<=3;
                3: begin
                    voice_hold <= product >>> 16;
                    multiply_a <= dry_hold;
                    multiply_b <= $signed({1'b0, (17'd65536-mix_hold)});
                    state<=4;
                end
                4: state<=5;
                5: begin
                    dry_product <= product;
                    multiply_a <= voice_hold;
                    multiply_b <= $signed({1'b0, mix_hold}); state<=6;
                end
                6: state<=7;
                7: begin
                    sum_q16 <= $signed({dry_product[39],dry_product}) +
                               $signed({product[39],product}); state<=8;
                end
                8: begin out_sample<=saturate(sum_q16); out_valid<=1; state<=0; end
                default: state<=0;
            endcase
        end
    end
endmodule
`default_nettype wire
