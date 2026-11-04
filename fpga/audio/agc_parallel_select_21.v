`timescale 1ns/1ps
`default_nettype none

// Requires the EXISTING AGC_32.v module agc_mean_21 for the clean branch.
// Both branches run continuously. Select is captured with each input sample.
module agc_parallel_select_21 #(
    parameter [20:0] CLEAN_TARGET_MEAN = 21'd262143,
    parameter integer IIR_SHIFT = 8,
    parameter integer PIPELINE_CONTROL = 0,
    parameter integer CONTROL_SHIFT = 4
)(
    input wire clk, rst_n, sample_ce,
    input wire signed [20:0] in_data,
    input wire distortion_enable,
    output wire signed [20:0] out_data,
    output wire out_valid,
    output wire [24:0] clean_gain_q24,
    output wire [20:0] clean_mean_level,
    output wire [28:0] distortion_gain_q24,
    output wire [20:0] distortion_mean_level,
    output wire distortion_clip_pulse
);
    wire signed [20:0] clean_audio, distortion_audio;
    wire clean_valid, distortion_valid;
    reg select_pipe, select_out, input_valid_d;

    agc_mean_21 #(
        .TARGET_MEAN(CLEAN_TARGET_MEAN), .PIPELINE_CONTROL(PIPELINE_CONTROL), .IIR_SHIFT(IIR_SHIFT), .CONTROL_SHIFT(CONTROL_SHIFT)
    ) u_clean (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce), .in_data(in_data),
        .out_data(clean_audio), .out_valid(clean_valid),
        .gain_q24(clean_gain_q24), .mean_level(clean_mean_level)
    );
    agc_hardclip_21 #(
        .TARGET_MEAN(21'd838860), .IIR_SHIFT(IIR_SHIFT),
        .CONTROL_SHIFT(CONTROL_SHIFT), .PIPELINE_CONTROL(PIPELINE_CONTROL), .MAX_GAIN(16)
    ) u_distortion (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce), .in_data(in_data),
        .out_data(distortion_audio), .out_valid(distortion_valid),
        .gain_q24(distortion_gain_q24), .mean_level(distortion_mean_level),
        .clip_pulse(distortion_clip_pulse)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            select_pipe <= 1'b0;
            select_out <= 1'b0;
            input_valid_d <= 1'b0;
        end else begin
            input_valid_d <= sample_ce;
            if (sample_ce) select_pipe <= distortion_enable;
            if (input_valid_d) select_out <= select_pipe;
        end
    end
    // Post-detector makeup attenuation: keep the hardclip feedback unscaled.
    // Signed arithmetic shift is -6.02 dB, with no added sample latency.
    wire signed [20:0] distortion_half = distortion_audio >>> 1;
    assign out_data = select_out ? distortion_half : clean_audio;
    assign out_valid = clean_valid;
endmodule
`default_nettype wire
