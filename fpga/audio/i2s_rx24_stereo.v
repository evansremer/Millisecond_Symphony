`timescale 1ns/1ps
`default_nettype none
// Standard I2S only: WS=0 left, WS=1 right, MSB one BCK after WS changes.
// Fixed 32 BCK/channel, 24-bit signed PCM. All logic uses clk, never BCK.
// Require clk >= 8*BCK and source changes WS/DIN on BCK falling edge.
module i2s_rx24_stereo (
    input wire clk, rst_n,
    input wire i2s_bck, i2s_lrck, i2s_din,
    output reg signed [23:0] pcm_left,
    output reg signed [23:0] pcm_right,
    output reg frame_valid,
    output reg format_error
);
    (* ASYNC_REG="TRUE" *) reg [2:0] bck_sync, ws_sync, din_sync;
    reg bck_previous, channel, aligned;
    reg [5:0] bit_count;
    reg [23:0] shift_data, left_hold, right_hold;
    reg left_good, right_good;
    wire rising_bck = bck_sync[2] && !bck_previous;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bck_sync<=0; ws_sync<=0; din_sync<=0; bck_previous<=0;
            channel<=0; aligned<=0; bit_count<=0; shift_data<=0;
            left_hold<=0; right_hold<=0; left_good<=0; right_good<=0;
            pcm_left<=0; pcm_right<=0; frame_valid<=0; format_error<=0;
        end else begin
            bck_sync <= {bck_sync[1:0],i2s_bck};
            ws_sync <= {ws_sync[1:0],i2s_lrck};
            din_sync <= {din_sync[1:0],i2s_din};
            bck_previous <= bck_sync[2];
            frame_valid<=0; format_error<=0;
            if (rising_bck) begin
                if (ws_sync[2] != channel) begin
                    // This edge still carries the preceding slot's last bit/padding.
                    // Start collecting the NEW channel at the NEXT BCK rising edge.
                    aligned<=1; channel<=ws_sync[2]; bit_count<=0; shift_data<=0;
                    if (aligned && bit_count != 6'd31) begin
                        format_error<=1; left_good<=0; right_good<=0;
                    end
                    if (!ws_sync[2]) begin
                        // Publish only after BOTH complete, correctly sized slots.
                        if (aligned && bit_count==6'd31 && left_good && right_good) begin
                            pcm_left<=left_hold; pcm_right<=right_hold; frame_valid<=1;
                        end
                        left_good<=0; right_good<=0;
                    end else right_good<=0;
                end else if (aligned) begin
                    if (bit_count != 6'd63) bit_count<=bit_count+1'b1;
                    if (bit_count < 6'd24) begin
                        shift_data <= {shift_data[22:0],din_sync[2]};
                        if (bit_count==6'd23) begin
                            if (!channel) begin
                                left_hold<={shift_data[22:0],din_sync[2]}; left_good<=1;
                            end else begin
                                right_hold<={shift_data[22:0],din_sync[2]}; right_good<=1;
                            end
                        end
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire
