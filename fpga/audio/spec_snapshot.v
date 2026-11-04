`timescale 1ns/1ps
`default_nettype none
// Dual-clock, double-bank spectrum store.
//
// The audio side writes one 10-bit band per cycle into the bank opposite the
// currently published request value, then toggles async_req after all 64 bands
// are complete.  The display side switches banks only on frame_tick and reads
// one band synchronously.  This removes the old 640-bit asynchronous bus and
// the per-pixel 640-to-10 dynamic mux from the display path.
module spec_snapshot (
    input  wire         audio_clk,
    input  wire         audio_rst_n,
    input  wire         wr_en,
    input  wire [5:0]   wr_addr,
    input  wire [9:0]   wr_data,
    input  wire         async_req,
    output reg          ack,
    input  wire         disp_clk,
    input  wire         reset,
    input  wire         frame_tick,
    input  wire [5:0]   rd_addr,
    output reg  [9:0]   rd_data,
    output reg          valid
);

    (* syn_ramstyle = "block_ram" *) reg [9:0] level_mem [0:127];
    (* ASYNC_REG = "TRUE" *) reg [2:0] req_sync;
    reg seen;
    reg active_bank;
    reg have_frame;

    always @(posedge audio_clk) begin
        if (audio_rst_n && wr_en)
            level_mem[{~async_req, wr_addr}] <= wr_data;
    end

    always @(posedge disp_clk) begin
        if (reset) begin
            req_sync <= 3'd0;
            seen     <= 1'b0;
            active_bank <= 1'b0;
            have_frame <= 1'b0;
            rd_data  <= 10'd0;
            valid    <= 1'b0;
            ack      <= 1'b0;
        end else begin
            req_sync <= {req_sync[1:0], async_req};
            valid    <= 1'b0;
            if (frame_tick && (req_sync[2] != seen)) begin
                seen  <= req_sync[2];
                active_bank <= req_sync[2];
                have_frame <= 1'b1;
                ack   <= req_sync[2];
                valid <= 1'b1;
            end
            if (have_frame)
                rd_data <= level_mem[{active_bank, rd_addr}];
            else
                rd_data <= 10'd0;
        end
    end

endmodule
`default_nettype wire
