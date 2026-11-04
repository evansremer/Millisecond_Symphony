`timescale 1ns/1ps
`default_nettype none

// Independent hard-clipping AGC. The detector observes the SATURATED output.
// No makeup attenuation or loudness matching is applied to the output.
module agc_hardclip_21 #(
    parameter [20:0] TARGET_MEAN = 21'd838860,
    parameter integer IIR_SHIFT = 8,
    parameter integer CONTROL_SHIFT = 4,
    parameter integer PIPELINE_CONTROL = 0,
    parameter integer MAX_GAIN = 16
)(
    input wire clk, rst_n, sample_ce,
    input wire signed [20:0] in_data,
    output reg signed [20:0] out_data,
    output reg out_valid,
    output reg [28:0] gain_q24,
    output reg [20:0] mean_level,
    output reg clip_pulse
);
    localparam [28:0] GAIN_ONE = 29'd16777216;
    localparam [28:0] GAIN_LIMIT = MAX_GAIN * GAIN_ONE;
    localparam integer IIR_BITS = 22 + IIR_SHIFT;
    localparam signed [50:0] AUDIO_MAX = 51'sd1048575;
    localparam signed [50:0] AUDIO_MIN = -51'sd1048576;

    // Unsigned Q5.24 includes the exact value 16. Signed multiply: 21 x 30.
    wire signed [29:0] signed_gain = $signed({1'b0, gain_q24});
    reg signed [50:0] product_reg;
    reg product_valid;
    wire signed [50:0] scaled_product = product_reg >>> 24;
    wire clipped = (scaled_product > AUDIO_MAX) || (scaled_product < AUDIO_MIN);
    wire signed [20:0] output_sample = (scaled_product > AUDIO_MAX) ? 21'sh0fffff :
                                       (scaled_product < AUDIO_MIN) ? 21'sh100000 :
                                       scaled_product[20:0];
    // 21 unsigned bits represent abs(-1048576) without overflow.
    wire [20:0] magnitude = output_sample[20] ? (~output_sample + 21'd1) : output_sample;
    reg signed [IIR_BITS-1:0] detector_acc;
    wire signed [IIR_BITS-1:0] magnitude_extended =
        $signed({{(IIR_BITS-21){1'b0}}, magnitude});
    wire signed [IIR_BITS-1:0] detector_next = detector_acc -
        (detector_acc >>> IIR_SHIFT) + magnitude_extended;
    wire [20:0] mean_next = detector_next >> IIR_SHIFT;

    wire signed [30:0] next_error = $signed({10'd0, mean_next}) - $signed({10'd0, TARGET_MEAN});
    reg signed [30:0] registered_error;
    reg gain_update;
    wire signed [30:0] level_error = PIPELINE_CONTROL ? registered_error : next_error;
    localparam signed [30:0] ROUND_HALF = (31'sd1 << CONTROL_SHIFT) >>> 1;
    wire signed [30:0] round_bias = level_error[30] ? (ROUND_HALF - 31'sd1) : ROUND_HALF;
    wire signed [30:0] control_step = CONTROL_SHIFT == 0 ? level_error : ((level_error + round_bias) >>> CONTROL_SHIFT);
    wire signed [30:0] gain_candidate = $signed({2'b00, gain_q24}) - control_step;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            registered_error <= 0;
            gain_update <= 0;
            product_reg <= 51'sd0;
            product_valid <= 1'b0;
            out_data <= 21'sd0;
            out_valid <= 1'b0;
            gain_q24 <= GAIN_ONE;
            detector_acc <= {IIR_BITS{1'b0}};
            mean_level <= 21'd0;
            clip_pulse <= 1'b0;
        end else begin
            gain_update <= product_valid;
            if (product_valid) registered_error <= next_error;
            product_valid <= sample_ce;
            out_valid <= product_valid;
            clip_pulse <= product_valid && clipped;
            if (sample_ce)
                product_reg <= in_data * signed_gain;
            if (product_valid) begin
                out_data <= output_sample;
                detector_acc <= detector_next;
                mean_level <= mean_next;
            end
            if (PIPELINE_CONTROL ? gain_update : product_valid) begin
                if (gain_candidate > $signed({2'b00, GAIN_LIMIT}))
                    gain_q24 <= GAIN_LIMIT;
                else if (gain_candidate < 31'sd0)
                    gain_q24 <= 29'd0;
                else
                    gain_q24 <= gain_candidate[28:0];
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (TARGET_MEAN == 0 || TARGET_MEAN > 21'd1048576 ||
            IIR_SHIFT < 1 || IIR_SHIFT > 20 || CONTROL_SHIFT < 0 || CONTROL_SHIFT > 20 ||
            MAX_GAIN < 1 || MAX_GAIN > 16) begin
            $display("HARDCLIP_PARAMETER_ERROR");
            $finish;
        end
    end
    // synthesis translate_on
endmodule
`default_nettype wire
