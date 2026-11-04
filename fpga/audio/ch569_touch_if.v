// CH569-to-FPGA touch transport receiver.
//
// Consumer interface (clk domain):
//   touch_valid : one clk pulse for every complete Exxx commit frame
//   touch_down  : contact state associated with touch_x/touch_y
//   touch_x/y   : 1920x1080 HDMI-source coordinates, held between reports
//   touch_state : 0=no status, 1=waiting, 2=enumerating, 3=error,
//                 4=USB HID touch ready
//
// Wire protocol (hspi_clk domain): A5xx=status, Bxxx=X, Cxxx=Y,
// Dxxx=touch-down, Exxx=atomic commit/sequence.  The CH569 repeats each
// 16-bit word throughout a DMA frame; the sequence fields suppress duplicates.
module ch569_touch_if(
    input  wire        clk,
    input  wire        resetn,
    input  wire [15:0] hspi_data,
    input  wire        hspi_clk,
    input  wire        hspi_req,
    input  wire        hspi_vld,
    output wire        hspi_rdy,
    output reg  [2:0]  touch_state,
    output reg         touch_valid,
    output reg         touch_down,
    output reg  [11:0] touch_x,
    output reg  [11:0] touch_y,
    output reg  [15:0] debug_word_pos,
    output reg  [15:0] debug_word_neg
);
    reg [2:0]  state_hspi;
    reg [11:0] x_hspi;
    reg [11:0] y_hspi;
    reg        down_hspi;
    reg [15:0] last_status_word;
    reg [15:0] last_commit_word;
    reg        state_toggle_hspi;
    reg        report_toggle_hspi;
    reg [8:0]  sample_count_pos;
    reg [8:0]  sample_count_neg;

    reg        state_toggle_meta;
    reg        state_toggle_sync;
    reg        state_toggle_seen;
    reg        report_toggle_meta;
    reg        report_toggle_sync;
    reg        report_toggle_seen;
    reg [2:0]  state_meta;
    reg [2:0]  state_sync;
    reg [11:0] x_meta;
    reg [11:0] x_sync;
    reg [11:0] y_meta;
    reg [11:0] y_sync;
    reg        down_meta;
    reg        down_sync;

    // The verified CH569 transmitter waits for this level before/while
    // transferring.  The current receive-only FPGA path is always ready.
    assign hspi_rdy = 1'b1;

    // Capture complete protocol words on the verified rising edge.
    always @(posedge hspi_clk or negedge resetn) begin
        if (!resetn) begin
            state_hspi         <= 3'd0;
            x_hspi             <= 12'd960;
            y_hspi             <= 12'd540;
            down_hspi          <= 1'b0;
            last_status_word   <= 16'hffff;
            last_commit_word   <= 16'hffff;
            state_toggle_hspi  <= 1'b0;
            report_toggle_hspi <= 1'b0;
            sample_count_pos   <= 9'd0;
            debug_word_pos     <= 16'h0000;
        end else begin
            if (hspi_vld) begin
                if (sample_count_pos == 9'd32)
                    debug_word_pos <= hspi_data;
                if (sample_count_pos != 9'h1ff)
                    sample_count_pos <= sample_count_pos + 1'b1;

                case (hspi_data[15:12])
                    4'hA: begin
                        if ((hspi_data[15:8] == 8'hA5) &&
                            (hspi_data != last_status_word)) begin
                            state_hspi        <= hspi_data[2:0];
                            last_status_word  <= hspi_data;
                            state_toggle_hspi <= ~state_toggle_hspi;
                        end
                    end
                    4'hB: x_hspi    <= hspi_data[11:0];
                    4'hC: y_hspi    <= hspi_data[11:0];
                    4'hD: down_hspi <= hspi_data[0];
                    4'hE: begin
                        if (hspi_data != last_commit_word) begin
                            last_commit_word   <= hspi_data;
                            report_toggle_hspi <= ~report_toggle_hspi;
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

    // Retained only as a bring-up observation point.  Hardware tests showed
    // the expected A501 diagnostic word on both edges, while the functional
    // receiver above consistently uses the rising edge.
    always @(negedge hspi_clk or negedge resetn) begin
        if (!resetn) begin
            sample_count_neg <= 9'd0;
            debug_word_neg   <= 16'h0000;
        end else if (hspi_vld) begin
            if (sample_count_neg == 9'd32)
                debug_word_neg <= hspi_data;
            if (sample_count_neg != 9'h1ff)
                sample_count_neg <= sample_count_neg + 1'b1;
        end
    end

    // Bundle-before-toggle CDC.  B/C/D are transmitted as separate, complete
    // DMA frames before E toggles report_toggle_hspi, so the multi-bit bundle
    // has settled long before the synchronized commit reaches this domain.
    always @(posedge clk) begin
        if (!resetn) begin
            state_toggle_meta  <= 1'b0;
            state_toggle_sync  <= 1'b0;
            state_toggle_seen  <= 1'b0;
            report_toggle_meta <= 1'b0;
            report_toggle_sync <= 1'b0;
            report_toggle_seen <= 1'b0;
            state_meta         <= 3'd0;
            state_sync         <= 3'd0;
            x_meta             <= 12'd960;
            x_sync             <= 12'd960;
            y_meta             <= 12'd540;
            y_sync             <= 12'd540;
            down_meta          <= 1'b0;
            down_sync          <= 1'b0;
            touch_state        <= 3'd0;
            touch_valid        <= 1'b0;
            touch_down         <= 1'b0;
            touch_x            <= 12'd960;
            touch_y            <= 12'd540;
        end else begin
            state_toggle_meta  <= state_toggle_hspi;
            state_toggle_sync  <= state_toggle_meta;
            report_toggle_meta <= report_toggle_hspi;
            report_toggle_sync <= report_toggle_meta;
            state_meta         <= state_hspi;
            state_sync         <= state_meta;
            x_meta             <= x_hspi;
            x_sync             <= x_meta;
            y_meta             <= y_hspi;
            y_sync             <= y_meta;
            down_meta          <= down_hspi;
            down_sync          <= down_meta;
            touch_valid        <= 1'b0;

            if (state_toggle_sync != state_toggle_seen) begin
                state_toggle_seen <= state_toggle_sync;
                touch_state       <= state_sync;
            end

            if (report_toggle_sync != report_toggle_seen) begin
                report_toggle_seen <= report_toggle_sync;
                touch_x            <= x_sync;
                touch_y            <= y_sync;
                touch_down         <= down_sync;
                touch_valid        <= 1'b1;
            end
        end
    end

    // HTRQ is retained at this boundary for pin-compatible future flow
    // control.  The verified receive-only path uses HTVLD plus E commits and
    // keeps HTRDY asserted, so HTRQ does not affect application data today.

endmodule
