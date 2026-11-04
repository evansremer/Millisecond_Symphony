`timescale 1ns/1ps
`default_nettype none
// One shared 24x19 signed multiplication expression for both channels.
// Gains are UNSIGNED Q6.12: 0=mute, 4096=1x, 16384=4x, max ~64x.
module stereo_gain24_to17 (
    input wire clk, rst_n,
    input wire in_valid,
    input wire signed [23:0] pcm_left, pcm_right,
    input wire [17:0] gain_left, gain_right,
    output reg [33:0] sample_bus, // [16:0] voice, [33:17] guitar; signed slices
    output reg out_valid,
    output wire busy,
    output reg overrun,
    output reg [1:0] clipped // valid with out_valid; bit0=L, bit1=R
);
    reg [2:0] state;
    reg signed [23:0] operand, right_hold;
    reg signed [18:0] coefficient;
    reg [17:0] right_gain_hold;
    reg signed [42:0] product;
    reg signed [23:0] rounded;
    reg [16:0] left_result;
    reg left_clipped;
    assign busy = state != 0;
    wire signed [23:0] integer_part = $signed(product[42:19]);
    // Remove 12 gain fractional bits + 7 PCM bits in one rounding step.
    wire increment = product[18] && (!product[42] || (|product[17:0]));
    wire signed [23:0] rounded_value = integer_part
                                      + (increment ? 24'sd1 : 24'sd0);
    wire positive_clip = rounded > 24'sd65535;
    wire negative_clip = rounded < -24'sd65536;
    wire [16:0] limited = positive_clip ? 17'h0ffff : negative_clip ? 17'h10000 : rounded[16:0];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=0; operand<=0; coefficient<=0; right_hold<=0; right_gain_hold<=0;
            product<=0; rounded<=0; left_result<=0; left_clipped<=0;
            sample_bus<=0; out_valid<=0; overrun<=0; clipped<=0;
        end else begin
            out_valid<=0;
            overrun<=in_valid && busy; // Busy arrivals are rejected, never partially captured.
            case (state)
                0: if (in_valid) begin
                    operand<=pcm_left; coefficient<=$signed({1'b0,gain_left});
                    right_hold<=pcm_right; right_gain_hold<=gain_right; state<=1;
                end
                1,4: begin product<=operand*coefficient; state<=state+1'b1; end
                2,5: begin rounded<=rounded_value; state<=state+1'b1; end
                3: begin
                    left_result<=limited; left_clipped<=positive_clip || negative_clip;
                    operand<=right_hold; coefficient<=$signed({1'b0,right_gain_hold}); state<=4;
                end
                6: begin
                    sample_bus<={limited,left_result};
                    clipped<={positive_clip || negative_clip,left_clipped};
                    out_valid<=1; state<=0;
                end
                default: state<=0;
            endcase
        end
    end
endmodule
`default_nettype wire
