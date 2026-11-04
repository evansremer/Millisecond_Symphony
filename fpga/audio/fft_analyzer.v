`timescale 1ns/1ps
`default_nettype none
// -----------------------------------------------------------------------------
// fft_analyzer -- two independent 1024-point FFT channels, 64 log bands
//
//   L and R are separate fft_channel instances running in parallel.  Each
//   channel is reduced to 64 band maxima, then the two band vectors are added.
//   The sum is converted to a 10-bit level, attack/release smoothed, and
//   committed as a 64x10-bit snapshot with a request/ack toggle.
// -----------------------------------------------------------------------------
module fft_analyzer #(
    parameter HANN_FILE = "fft_hann.mem",
    parameter TWIDDLE_FILE = "fft_twiddle.mem",
    parameter BAND_FILE = "fft_band_edges.mem",
    parameter LOG2_FILE = "fft_log2.mem"
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire signed [23:0] pcm_left,
    input  wire signed [23:0] pcm_right,
    input  wire               pcm_valid,
    output wire raw_valid,output wire [8:0] raw_index,output wire [23:0] raw_data,
    output wire               busy,
    output wire               capture_overrun,
    output wire               result_overrun,
    output reg                spec_wr_en,
    output reg  [5:0]         spec_wr_addr,
    output reg  [9:0]         spec_wr_data,
    output reg                spec_req,
    input  wire               spec_ack,
    output reg                spec_drop,
    output reg                frame_commit
);

    // ---------------------------------------------------------------------
    // Two parallel FFT channels
    // ---------------------------------------------------------------------
    
    wire        busy_l, busy_r;
    wire        frame_valid_l, frame_valid_r;
    wire        bin_valid_l, bin_valid_r;
    wire [9:0]  bin_index_l, bin_index_r;
    wire [20:0] bin_mag_l, bin_mag_r;
    // Display only: linear per-bin magnitudes, scaled uniformly with the
    // previous complete frame peak (excluding DC). Audio/64-band path unchanged.
    function [4:0] peak_exponent;
        input [20:0] magnitude;
        begin casez(magnitude)
            21'b1????????????????????:peak_exponent=5'd20;
            21'b01???????????????????:peak_exponent=5'd19;
            21'b001??????????????????:peak_exponent=5'd18;
            21'b0001?????????????????:peak_exponent=5'd17;
            21'b00001????????????????:peak_exponent=5'd16;
            21'b000001???????????????:peak_exponent=5'd15;
            21'b0000001??????????????:peak_exponent=5'd14;
            21'b00000001?????????????:peak_exponent=5'd13;
            21'b000000001????????????:peak_exponent=5'd12;
            21'b0000000001???????????:peak_exponent=5'd11;
            21'b00000000001??????????:peak_exponent=5'd10;
            21'b000000000001?????????:peak_exponent=5'd9;
            21'b0000000000001????????:peak_exponent=5'd8;
            21'b00000000000001???????:peak_exponent=5'd7;
            21'b000000000000001??????:peak_exponent=5'd6;
            21'b0000000000000001?????:peak_exponent=5'd5;
            21'b00000000000000001????:peak_exponent=5'd4;
            21'b000000000000000001???:peak_exponent=5'd3;
            21'b0000000000000000001??:peak_exponent=5'd2;
            21'b00000000000000000001?:peak_exponent=5'd1;
            21'b000000000000000000001:peak_exponent=5'd0;
            default:peak_exponent=0;
        endcase end
    endfunction
    function [11:0] saturate_display;
        input [41:0] value;
        begin saturate_display=(|value[41:12])?12'd4095:value[11:0];end
    endfunction
    wire bins_valid=bin_valid_l && bin_valid_r;
    wire [20:0] pair_peak=bin_mag_l>bin_mag_r?bin_mag_l:bin_mag_r;
    reg [20:0] display_peak;reg finalize_peak,display_gate;reg [4:0] display_shift;
    reg [41:0] display_scaled_l,display_scaled_r;
    reg raw_valid_pipe,raw_valid_q;reg [8:0] raw_index_pipe,raw_index_q;reg [23:0] raw_data_q;
    assign raw_valid=raw_valid_q;assign raw_index=raw_index_q;assign raw_data=raw_data_q;
    always @(posedge clk)begin
        if(!rst_n)begin
            display_peak<=0;finalize_peak<=0;display_shift<=31;display_gate<=0;
            display_scaled_l<=0;display_scaled_r<=0;
            raw_valid_pipe<=0;raw_valid_q<=0;raw_index_pipe<=0;raw_index_q<=0;raw_data_q<=0;
        end else begin
            finalize_peak<=bins_valid && bin_index_l==10'd511;
            if(finalize_peak)begin display_shift<=peak_exponent(display_peak)+5'd11;display_gate<=display_peak>=8;end
            if(bins_valid)begin
                if(bin_index_l==0)display_peak<=0;else if(pair_peak>display_peak)display_peak<=pair_peak;
                display_scaled_l<=bin_index_l==0 || !display_gate?42'd0:({bin_mag_l,21'd0}>>display_shift);
                display_scaled_r<=bin_index_l==0 || !display_gate?42'd0:({bin_mag_r,21'd0}>>display_shift);
                raw_index_pipe<=bin_index_l[8:0];
            end
            raw_valid_pipe<=bins_valid;raw_valid_q<=raw_valid_pipe;
            if(raw_valid_pipe)begin
                raw_index_q<=raw_index_pipe;
                raw_data_q<={saturate_display(display_scaled_r),saturate_display(display_scaled_l)};
            end
        end
    end
    wire        cap_over_l, cap_over_r;
    wire        res_over_l, res_over_r;

    wire [17:0] shared_hann;wire [35:0] shared_twiddle;
    wire [9:0] hann_addr_l,hann_addr_r;wire [8:0] tw_addr_l,tw_addr_r;

    fft_channel #(
        .HANN_FILE(HANN_FILE),
        .TWIDDLE_FILE(TWIDDLE_FILE)
    ) u_fft_l (
        .clk(clk), .rst_n(rst_n),
        .sample_in(pcm_left), .sample_valid(pcm_valid),
        .busy(busy_l), .frame_valid(frame_valid_l),
        .bin_valid(bin_valid_l), .bin_index(bin_index_l), .bin_mag(bin_mag_l),
        .capture_overrun(cap_over_l), .result_overrun(res_over_l),
        .coefficient_hann(shared_hann),.coefficient_twiddle(shared_twiddle),
        .coefficient_hann_addr(hann_addr_l),.coefficient_twiddle_addr(tw_addr_l)
    );

    fft_channel #(
        .HANN_FILE(HANN_FILE),
        .TWIDDLE_FILE(TWIDDLE_FILE)
        ,.EXTERNAL_COEFFICIENTS(1)
    ) u_fft_r (
        .clk(clk), .rst_n(rst_n),
        .sample_in(pcm_right), .sample_valid(pcm_valid),
        .busy(busy_r), .frame_valid(frame_valid_r),
        .bin_valid(bin_valid_r), .bin_index(bin_index_r), .bin_mag(bin_mag_r),
        .capture_overrun(cap_over_r), .result_overrun(res_over_r),
        .external_hann(shared_hann),.external_twiddle(shared_twiddle),
        .coefficient_hann_addr(hann_addr_r),.coefficient_twiddle_addr(tw_addr_r)
    );

    // ---------------------------------------------------------------------
    // Band edges and log2 LUT
    // ---------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk)if(rst_n && {hann_addr_l,tw_addr_l} !== {hann_addr_r,tw_addr_r})
        $fatal(1,"Stereo coefficient address divergence");
    // synthesis translate_on

    // SUG550 section 5.16: "logic" keeps this tiny, registered threshold
    // lookup out of BSRAM. Preserve BAND_FILE and the retimed read latency.
    reg [8:0]  band_edge [0:64] /* synthesis syn_romstyle="logic" */;
    reg [15:0] log2_lut [0:63];

    initial begin
        $readmemh(BAND_FILE, band_edge);
        $readmemh(LOG2_FILE, log2_lut);
    end

    (* syn_ramstyle = "distributed_ram", ram_style="distributed" *) reg [11:0] band_l [0:63];
    (* syn_ramstyle = "distributed_ram", ram_style="distributed" *) reg [11:0] band_r [0:63];
    reg [5:0]  band_idx_l, band_idx_r;
    reg [11:0] band_peak_l, band_peak_r;
    reg [5:0]  band_rd_addr;
    reg [11:0] band_rd_l, band_rd_r;
    reg        busy_l_d, busy_r_d;
    reg        pending_l, pending_r;

    wire start_l = busy_l && !busy_l_d;
    wire start_r = busy_r && !busy_r_d;

    wire [6:0] edge_idx_l = {1'b0, band_idx_l} + 7'd1;
    wire [6:0] edge_idx_r = {1'b0, band_idx_r} + 7'd1;
    reg [8:0] edge_l,edge_r;
    // FFT emits one bin every three clocks. The updated band edge is ready
    // two clocks before the next bin; no spectrum output latency changes.
    always @(posedge clk)begin
        edge_l <= band_edge[edge_idx_l];
        edge_r <= band_edge[edge_idx_r];
    end
    wire [11:0] mag12_l = bin_mag_l[20:9];
    wire [11:0] mag12_r = bin_mag_r[20:9];
    wire [11:0] peak_next_l = (mag12_l > band_peak_l) ? mag12_l : band_peak_l;
    wire [11:0] peak_next_r = (mag12_r > band_peak_r) ? mag12_r : band_peak_r;
    wire end_band_l = ({1'b0, bin_index_l} + 11'd1) >= {2'b00, edge_l};
    wire end_band_r = ({1'b0, bin_index_r} + 11'd1) >= {2'b00, edge_r};

    // FFT bins arrive in increasing order, so only the running peak for the
    // current band is needed.  A completed band is written once to RAM.  This
    // replaces the former 64-way decoded register write-enable network.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_l_d <= 1'b0;
            busy_r_d <= 1'b0;
            band_idx_l <= 6'd0;
            band_idx_r <= 6'd0;
            band_peak_l <= 12'd0;
            band_peak_r <= 12'd0;
            band_rd_l <= 12'd0;
            band_rd_r <= 12'd0;
        end else begin
            busy_l_d <= busy_l;
            busy_r_d <= busy_r;
            band_rd_l <= band_l[band_rd_addr];
            band_rd_r <= band_r[band_rd_addr];

            if (start_l) begin
                band_idx_l <= 6'd0;
                band_peak_l <= 12'd0;
            end else if (bin_valid_l && (bin_index_l >= 10'd1) &&
                         (bin_index_l <= 10'd426)) begin
                if (end_band_l) begin
                    band_l[band_idx_l] <= peak_next_l;
                    band_peak_l <= 12'd0;
                    if (band_idx_l != 6'd63)
                        band_idx_l <= band_idx_l + 6'd1;
                end else begin
                    band_peak_l <= peak_next_l;
                end
            end

            if (start_r) begin
                band_idx_r <= 6'd0;
                band_peak_r <= 12'd0;
            end else if (bin_valid_r && (bin_index_r >= 10'd1) &&
                         (bin_index_r <= 10'd426)) begin
                if (end_band_r) begin
                    band_r[band_idx_r] <= peak_next_r;
                    band_peak_r <= 12'd0;
                    if (band_idx_r != 6'd63)
                        band_idx_r <= band_idx_r + 6'd1;
                end else begin
                    band_peak_r <= peak_next_r;
                end
            end

        end
    end

    // ---------------------------------------------------------------------
    // Combine, dB compression, attack/release, snapshot
    // ---------------------------------------------------------------------
    localparam [3:0] INIT_ST      = 4'd0;
    localparam [3:0] WAIT_ST      = 4'd1;
    localparam [3:0] DB_ADDR_ST   = 4'd2;
    localparam [3:0] DB_WAIT_ST   = 4'd3;
    localparam [3:0] DB_SUM_ST    = 4'd4;
    localparam [3:0] DB_NORM_ST   = 4'd5;
    localparam [3:0] DB_LOG_ST    = 4'd6;
    localparam [3:0] DB_SMOOTH_ST = 4'd7;
    localparam [3:0] DB_WRITE_ST  = 4'd8;
    localparam [3:0] COMMIT_ST    = 4'd9;
    localparam [3:0] DB_SCALE_ST  = 4'd10;

    reg [3:0]  state;
    reg [5:0]  idx;
    (* syn_ramstyle = "distributed_ram", ram_style="distributed" *) reg [9:0] shown [0:63];
    reg        shown_wr_en;
    reg [5:0]  shown_wr_addr;
    reg [9:0]  shown_wr_data;
    reg [5:0]  shown_rd_addr;
    reg [9:0]  shown_rd_data;
    reg [1:0]  ack_sync;
    reg        ack_seen;
    reg [21:0] band_sum_q;
    reg        log_zero_q;
    reg [4:0]  log_exp_q;
    reg [5:0]  log_mant_q;
    reg [19:0] delta_q;
    reg [9:0]  level_q;
    reg [9:0]  smooth_q;

    // The displayed level is a true synchronous RAM.  Besides saving the
    // 64x10 register bank, this removes the old idx -> 64-way mux -> log ->
    // smooth -> 64-way decoded write path that dominated audio_core_clk.
    always @(posedge clk) begin
        if (shown_wr_en)
            shown[shown_wr_addr] <= shown_wr_data;
        shown_rd_data <= shown[shown_rd_addr];
    end

    // Leading-one / 6-bit mantissa, then a 64-entry log2 LUT.  The final
    // constant multiply by 171 is shift/add only (no DSP multiplier).
    reg [4:0]  clz;
    reg [22:0] norm;
    reg [5:0]  mant;
    reg [4:0]  exp_c;
    reg [15:0] frac;
    reg [20:0] logq;
    reg [19:0] delta;
    reg [27:0] scaled;
    reg [10:0] level_w;
    reg [9:0]  level_c;

    always @(*) begin
        if (band_sum_q == 22'd0) begin
            clz = 5'd20;
            norm = 23'd0;
            mant = 6'd0;
            exp_c = 5'd0;
        end else begin
            if      (band_sum_q[20]) clz = 5'd0;
            else if (band_sum_q[19]) clz = 5'd1;
            else if (band_sum_q[18]) clz = 5'd2;
            else if (band_sum_q[17]) clz = 5'd3;
            else if (band_sum_q[16]) clz = 5'd4;
            else if (band_sum_q[15]) clz = 5'd5;
            else if (band_sum_q[14]) clz = 5'd6;
            else if (band_sum_q[13]) clz = 5'd7;
            else if (band_sum_q[12]) clz = 5'd8;
            else if (band_sum_q[11]) clz = 5'd9;
            else if (band_sum_q[10]) clz = 5'd10;
            else if (band_sum_q[9])  clz = 5'd11;
            else if (band_sum_q[8])  clz = 5'd12;
            else if (band_sum_q[7])  clz = 5'd13;
            else if (band_sum_q[6])  clz = 5'd14;
            else if (band_sum_q[5])  clz = 5'd15;
            else if (band_sum_q[4])  clz = 5'd16;
            else if (band_sum_q[3])  clz = 5'd17;
            else if (band_sum_q[2])  clz = 5'd18;
            else if (band_sum_q[1])  clz = 5'd19;
            else                    clz = 5'd20;

            norm = {1'b0, band_sum_q} << (clz + 5'd1);
            mant = norm[20:15];
            exp_c = 5'd20 - clz;
        end
    end

    // Display-only pipeline: separate LUT/threshold from the x171 scaling.
    // One additional clock per display band; FFT/audio sampling is unchanged.
    always @(*) begin
        if (log_zero_q) begin
            frac = 16'd0;
            logq = 21'd0;
            delta = 20'd0;
        end else begin
            frac = log2_lut[log_mant_q];
            logq = {log_exp_q, 16'd0} + {5'd0, frac};
            if (logq <= 21'd395907)
                delta = 20'd0;
            else
                delta = logq[19:0] - 20'd395907;
        end
    end
    always @(*) begin
        scaled = (delta_q << 7) + (delta_q << 5) + (delta_q << 3) +
                 (delta_q << 1) + delta_q;
        level_w = scaled[27:17];
        level_c = level_w > 11'd1023 ? 10'd1023 : level_w[9:0];
    end

    reg [9:0] smooth_c;
    reg [9:0] smooth_diff;
    reg [9:0] smooth_dec;
    always @(*) begin
        if (level_q >= shown_rd_data) begin
            smooth_diff = level_q - shown_rd_data;
            smooth_dec = 10'd0;
            smooth_c = shown_rd_data +
                       ((smooth_diff > 10'd1) ? (smooth_diff >> 1) : 10'd1);
        end else begin
            smooth_diff = 10'd0;
            smooth_dec = ((shown_rd_data >> 4) == 10'd0) ?
                         10'd1 : (shown_rd_data >> 4);
            smooth_c = shown_rd_data - smooth_dec;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= INIT_ST;
            idx <= 6'd0;
            shown_wr_en <= 1'b0;
            shown_wr_addr <= 6'd0;
            shown_wr_data <= 10'd0;
            shown_rd_addr <= 6'd0;
            band_rd_addr <= 6'd0;
            spec_wr_en <= 1'b0;
            spec_wr_addr <= 6'd0;
            spec_wr_data <= 10'd0;
            spec_req <= 1'b0;
            spec_drop <= 1'b0;
            frame_commit <= 1'b0;
            pending_l <= 1'b0;
            pending_r <= 1'b0;
            ack_sync <= 2'd0;
            ack_seen <= 1'b0;
            band_sum_q <= 22'd0;
            log_zero_q <= 1'b1;
            log_exp_q <= 5'd0;
            log_mant_q <= 6'd0;
            delta_q <= 20'd0;
            level_q <= 10'd0;
            smooth_q <= 10'd0;
        end else begin
            frame_commit <= 1'b0;
            spec_wr_en <= 1'b0;
            shown_wr_en <= 1'b0;
            ack_sync <= {ack_sync[0], spec_ack};
            ack_seen <= ack_sync[1];

            if (frame_valid_l) pending_l <= 1'b1;
            if (frame_valid_r) pending_r <= 1'b1;

            case (state)
                INIT_ST: begin
                    shown_wr_en <= 1'b1;
                    shown_wr_addr <= idx;
                    shown_wr_data <= 10'd0;
                    if (idx == 6'd63) begin
                        idx <= 6'd0;
                        state <= WAIT_ST;
                    end else begin
                        idx <= idx + 6'd1;
                    end
                end

                WAIT_ST: begin
                    if ((pending_l || frame_valid_l) &&
                        (pending_r || frame_valid_r) &&
                        (spec_req == ack_seen)) begin
                        state <= DB_ADDR_ST;
                        idx <= 6'd0;
                        pending_l <= 1'b0;
                        pending_r <= 1'b0;
                    end
                end

                DB_ADDR_ST: begin
                    band_rd_addr <= idx;
                    shown_rd_addr <= idx;
                    state <= DB_WAIT_ST;
                end

                DB_WAIT_ST: begin
                    state <= DB_SUM_ST;
                end

                DB_SUM_ST: begin
                    band_sum_q <= {1'b0, band_rd_l, 9'd0} +
                                  {1'b0, band_rd_r, 9'd0};
                    state <= DB_NORM_ST;
                end

                DB_NORM_ST: begin
                    log_zero_q <= (band_sum_q == 22'd0);
                    log_exp_q <= exp_c;
                    log_mant_q <= mant;
                    state <= DB_LOG_ST;
                end

                DB_LOG_ST: begin
                    delta_q <= delta;
                    state <= DB_SCALE_ST;
                end

                DB_SCALE_ST: begin
                    level_q <= level_c;
                    state <= DB_SMOOTH_ST;
                end

                DB_SMOOTH_ST: begin
                    smooth_q <= smooth_c;
                    state <= DB_WRITE_ST;
                end

                DB_WRITE_ST: begin
                    shown_wr_en <= 1'b1;
                    shown_wr_addr <= idx;
                    shown_wr_data <= smooth_q;
                    spec_wr_en <= 1'b1;
                    spec_wr_addr <= idx;
                    spec_wr_data <= smooth_q;
                    if (idx == 6'd63)
                        state <= COMMIT_ST;
                    else begin
                        idx <= idx + 6'd1;
                        state <= DB_ADDR_ST;
                    end
                end

                COMMIT_ST: begin
                    frame_commit <= 1'b1;
                    if (spec_req == ack_seen) begin
                        spec_req <= ~spec_req;
                    end else begin
                        spec_drop <= 1'b1;
                    end
                    state <= WAIT_ST;
                end

                default: state <= WAIT_ST;
            endcase
        end
    end

    assign busy = busy_l | busy_r | frame_valid_l | frame_valid_r |
                  pending_l | pending_r | (state != WAIT_ST);
    assign capture_overrun = cap_over_l | cap_over_r;
    assign result_overrun = res_over_l | res_over_r;

endmodule
`default_nettype wire
