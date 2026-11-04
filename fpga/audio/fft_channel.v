`timescale 1ns/1ps
`default_nettype none
// -----------------------------------------------------------------------------
// fft_channel -- one 1024-point real-input FFT channel
//
//   * 24-bit PCM -> rounded/saturated 20-bit signed
//   * double-bank capture RAM (1024 samples per bank)
//   * Hann window, 18-bit Q1.17
//   * one complex work RAM, one 4-real-multiply butterfly
//   * DIT, bit-reversed load, natural-order output
//   * 10 stages, fixed >>1 per stage
//   * positive bins 0..511 streamed with magnitude approximation
//
//   This module deliberately contains one channel only.  S3 instantiates two
//   of these channels in parallel.
// -----------------------------------------------------------------------------
module fft_channel #(
    parameter HANN_FILE = "fft_hann.mem",
    parameter TWIDDLE_FILE = "fft_twiddle.mem",
    parameter integer EXTERNAL_COEFFICIENTS=0
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire signed [23:0] sample_in,
    input  wire               sample_valid,
    output reg                busy,
    output reg                frame_valid,
    output reg                bin_valid,
    output reg  [9:0]         bin_index,
    output reg  [20:0]        bin_mag,
    output reg                capture_overrun,
    output reg                result_overrun,
    input wire [17:0] external_hann, input wire [35:0] external_twiddle,
    output wire [17:0] coefficient_hann, output wire [35:0] coefficient_twiddle,
    output wire [9:0] coefficient_hann_addr, output wire [8:0] coefficient_twiddle_addr
);

    localparam [4:0] IDLE        = 5'd0;
    localparam [4:0] LOAD_ADDR   = 5'd1;
    localparam [4:0] LOAD_WAIT   = 5'd2;
    localparam [4:0] LOAD_LATCH  = 5'd3;
    localparam [4:0] LOAD_MUL    = 5'd4;
    localparam [4:0] LOAD_WRITE  = 5'd5;
    localparam [4:0] FFT_SETUP   = 5'd6;
    localparam [4:0] FFT_RD_A    = 5'd7;
    localparam [4:0] FFT_WAIT_A  = 5'd8;
    localparam [4:0] FFT_LATCH_A = 5'd9;
    localparam [4:0] FFT_WAIT_B  = 5'd10;
    localparam [4:0] FFT_LATCH_B = 5'd11;
    localparam [4:0] FFT_MULT    = 5'd12;
    localparam [4:0] FFT_PROD    = 5'd13;
    localparam [4:0] FFT_WR_A    = 5'd14;
    localparam [4:0] FFT_WR_B    = 5'd15;
    localparam [4:0] MAG_SETUP   = 5'd16;
    localparam [4:0] MAG_RD      = 5'd17;
    localparam [4:0] MAG_WAIT    = 5'd18;
    localparam [4:0] MAG_OUT     = 5'd19;

    // ---------------------------------------------------------------------
    // Capture RAM and work RAM
    // ---------------------------------------------------------------------
    reg signed [19:0] cap0 [0:1023];
    reg signed [19:0] cap1 [0:1023];
    reg signed [19:0] work_re [0:1023];
    reg signed [19:0] work_im [0:1023];

    // ---------------------------------------------------------------------
    // Input rounding/saturation: 24-bit signed -> 20-bit signed
    // ---------------------------------------------------------------------
    wire signed [24:0] sample_round = {{1{sample_in[23]}}, sample_in} + 25'sd8;
    wire signed [24:0] sample_shift = sample_round >>> 4;
    wire signed [19:0] sample20 =
        (sample_shift > 25'sd524287)  ? 20'sh7ffff :
        (sample_shift < -25'sd524288) ? 20'sh80000 :
                                        sample_shift[19:0];

    reg        cap_bank;
    reg [9:0]  cap_wr;
    reg        fft_bank;
    reg        start_req;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cap_bank        <= 1'b0;
            cap_wr          <= 10'd0;
            fft_bank        <= 1'b0;
            start_req       <= 1'b0;
            capture_overrun <= 1'b0;
        end else begin
            if (sample_valid) begin
                if (cap_bank) cap1[cap_wr] <= sample20;
                else          cap0[cap_wr] <= sample20;

                if (cap_wr == 10'd1023) begin
                    cap_wr <= 10'd0;
                    if (!busy && !start_req) begin
                        fft_bank  <= cap_bank;
                        cap_bank  <= ~cap_bank;
                        start_req <= 1'b1;
                    end else begin
                        // Keep writing the same bank so a busy FFT never has
                        // its read bank overwritten.
                        capture_overrun <= 1'b1;
                    end
                end else begin
                    cap_wr <= cap_wr + 10'd1;
                end
            end
            // The FFT FSM raises busy when it accepts start_req.
            if (start_req && busy)
                start_req <= 1'b0;
        end
    end

    reg [9:0] cap_rd_addr;
    reg       cap_rd_en;
    reg signed [19:0] cap_rd_data;

    always @(posedge clk) begin
        if (cap_rd_en) begin
            if (fft_bank) cap_rd_data <= cap1[cap_rd_addr];
            else          cap_rd_data <= cap0[cap_rd_addr];
        end
    end

    reg [9:0]  wr_addr;
    reg signed [19:0] wr_re, wr_im;
    reg        wr_en;
    reg [9:0]  rd_addr;
    reg        rd_en;
    reg signed [19:0] rd_re, rd_im;

    always @(posedge clk) begin
        if (wr_en) begin
            work_re[wr_addr] <= wr_re;
            work_im[wr_addr] <= wr_im;
        end
        if (rd_en) begin
            rd_re <= work_re[rd_addr];
            rd_im <= work_im[rd_addr];
        end
    end

    // ---------------------------------------------------------------------
    // Coefficient ROMs (registered outputs)
    // ---------------------------------------------------------------------
    reg [9:0]  hann_addr;
    wire [17:0] hann_q;
    reg [8:0]  tw_addr;
    wire [35:0] tw_q;

    assign coefficient_hann=hann_q;assign coefficient_twiddle=tw_q;
    assign coefficient_hann_addr=hann_addr;assign coefficient_twiddle_addr=tw_addr;
    generate if(EXTERNAL_COEFFICIENTS)begin:external_rom
        assign hann_q=external_hann;assign tw_q=external_twiddle;
    end else begin:local_rom
        (* rom_style="block" *) reg [17:0] hann_rom[0:1023];
        (* rom_style="block" *) reg [35:0] tw_rom[0:511];
        reg [17:0] hq;reg [35:0] tq;
        initial begin $readmemh(HANN_FILE,hann_rom);$readmemh(TWIDDLE_FILE,tw_rom);end
        always @(posedge clk)begin hq<=hann_rom[hann_addr];tq<=tw_rom[tw_addr];end
        assign hann_q=hq;assign tw_q=tq;
    end endgenerate

    // ---------------------------------------------------------------------
    // Bit reverse and butterfly addresses
    // ---------------------------------------------------------------------
    function [9:0] bitrev10;
        input [9:0] value;
        begin
            bitrev10 = {value[0], value[1], value[2], value[3], value[4],
                        value[5], value[6], value[7], value[8], value[9]};
        end
    endfunction

    function signed [19:0] sat20;
        input signed [24:0] value;
        begin
            if (value > 25'sd524287)
                sat20 = 20'sh7ffff;
            else if (value < -25'sd524288)
                sat20 = 20'sh80000;
            else
                sat20 = value[19:0];
        end
    endfunction

    reg [9:0]  stage;
    reg [9:0]  bf;

    wire [9:0] half    = 10'd1 << stage;
    wire [9:0] bf_j    = bf & (half - 10'd1);
    wire [8:0] tw_idx  = bf_j[8:0] << (4'd9 - stage[3:0]);
    wire [9:0] bf_grp  = bf >> stage[3:0];
    wire [9:0] addr_a  = (bf_grp << (stage[3:0] + 4'd1)) + bf_j;
    wire [9:0] addr_b  = addr_a + half;

    // ---------------------------------------------------------------------
    // Data registers
    // ---------------------------------------------------------------------
    reg [4:0]  state;
    reg [9:0]  load_idx;
    reg signed [19:0] load_sample;
    reg signed [38:0] hann_prod;

    reg signed [19:0] a_re, a_im, b_re, b_im;
    reg signed [37:0] m0, m1, m2, m3;
    reg signed [19:0] w0_re, w0_im, w1_re, w1_im;

    reg [9:0]  mag_idx;

    wire signed [17:0] tw_re = tw_q[35:18];
    wire signed [17:0] tw_im = tw_q[17:0];

    wire signed [24:0] hann_round = (hann_prod + 39'sd65536) >>> 17;

    // Complex products, 20-bit data x 18-bit Q1.17.
    wire signed [39:0] t_re_full = {{2{m0[37]}}, m0} -
                                   {{2{m1[37]}}, m1} + 40'sd65536;
    wire signed [39:0] t_im_full = {{2{m2[37]}}, m2} +
                                   {{2{m3[37]}}, m3} + 40'sd65536;
    wire signed [22:0] t_re = t_re_full >>> 17;
    wire signed [22:0] t_im = t_im_full >>> 17;

    wire signed [24:0] a_re_ext = {{5{a_re[19]}}, a_re};
    wire signed [24:0] a_im_ext = {{5{a_im[19]}}, a_im};
    wire signed [24:0] t_re_ext = {{2{t_re[22]}}, t_re};
    wire signed [24:0] t_im_ext = {{2{t_im[22]}}, t_im};

    wire signed [24:0] y0_re_full = a_re_ext + t_re_ext + 25'sd1;
    wire signed [24:0] y0_im_full = a_im_ext + t_im_ext + 25'sd1;
    wire signed [24:0] y1_re_full = a_re_ext - t_re_ext + 25'sd1;
    wire signed [24:0] y1_im_full = a_im_ext - t_im_ext + 25'sd1;

    wire signed [19:0] y0_re = sat20(y0_re_full >>> 1);
    wire signed [19:0] y0_im = sat20(y0_im_full >>> 1);
    wire signed [19:0] y1_re = sat20(y1_re_full >>> 1);
    wire signed [19:0] y1_im = sat20(y1_im_full >>> 1);

    // Magnitude approximation: max + 3/8*min, no multiplier.
    wire [19:0] abs_re = rd_re[19] ? (~rd_re + 20'd1) : rd_re;
    wire [19:0] abs_im = rd_im[19] ? (~rd_im + 20'd1) : rd_im;
    wire [19:0] mag_max = (abs_re >= abs_im) ? abs_re : abs_im;
    wire [19:0] mag_min = (abs_re >= abs_im) ? abs_im : abs_re;
    wire [20:0] mag_sum = {1'b0, mag_max} +
                          {1'b0, mag_min[19:2]} +
                          {1'b0, mag_min[19:3]};
    reg [20:0] mag_sum_q;

    // ---------------------------------------------------------------------
    // Main FSM
    // ---------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= IDLE;
            busy            <= 1'b0;
            frame_valid     <= 1'b0;
            bin_valid       <= 1'b0;
            bin_index       <= 10'd0;
            bin_mag         <= 21'd0;
            result_overrun  <= 1'b0;
            load_idx        <= 10'd0;
            load_sample     <= 20'd0;
            hann_prod       <= 39'd0;
            a_re <= 20'd0; a_im <= 20'd0; b_re <= 20'd0; b_im <= 20'd0;
            m0 <= 38'd0; m1 <= 38'd0; m2 <= 38'd0; m3 <= 38'd0;
            w0_re <= 20'd0; w0_im <= 20'd0; w1_re <= 20'd0; w1_im <= 20'd0;
            wr_addr <= 10'd0; wr_re <= 20'd0; wr_im <= 20'd0; wr_en <= 1'b0;
            rd_addr <= 10'd0; rd_en <= 1'b0;
            cap_rd_addr <= 10'd0; cap_rd_en <= 1'b0;
            hann_addr <= 10'd0; tw_addr <= 9'd0;
            stage <= 10'd0; bf <= 10'd0;
            mag_idx <= 10'd0;
        end else begin
            frame_valid <= 1'b0;
            bin_valid   <= 1'b0;
            wr_en       <= 1'b0;
            rd_en       <= 1'b0;
            cap_rd_en   <= 1'b0;

            case (state)
                IDLE: begin
                    if (start_req) begin
                        busy      <= 1'b1;
                        load_idx  <= 10'd0;
                        state     <= LOAD_ADDR;
                    end
                end

                LOAD_ADDR: begin
                    cap_rd_addr <= load_idx;
                    cap_rd_en   <= 1'b1;
                    hann_addr   <= load_idx;
                    state       <= LOAD_WAIT;
                end

                LOAD_WAIT: begin
                    state <= LOAD_LATCH;
                end

                LOAD_LATCH: begin
                    load_sample <= cap_rd_data;
                    cap_rd_en   <= 1'b0;
                    state       <= LOAD_MUL;
                end

                LOAD_MUL: begin
                    hann_prod <= load_sample * $signed({1'b0, hann_q});
                    state     <= LOAD_WRITE;
                end

                LOAD_WRITE: begin
                    wr_addr <= bitrev10(load_idx);
                    wr_re   <= sat20(hann_round[24:0]);
                    wr_im   <= 20'd0;
                    wr_en   <= 1'b1;
                    if (load_idx == 10'd1023) begin
                        stage <= 10'd0;
                        bf    <= 10'd0;
                        state <= FFT_SETUP;
                    end else begin
                        load_idx <= load_idx + 10'd1;
                        state    <= LOAD_ADDR;
                    end
                end

                FFT_SETUP: begin
                    stage <= 10'd0;
                    bf    <= 10'd0;
                    state <= FFT_RD_A;
                end

                FFT_RD_A: begin
                    rd_addr <= addr_a;
                    rd_en   <= 1'b1;
                    tw_addr <= tw_idx;
                    state   <= FFT_WAIT_A;
                end

                FFT_WAIT_A: begin
                    state <= FFT_LATCH_A;
                end

                FFT_LATCH_A: begin
                    a_re    <= rd_re;
                    a_im    <= rd_im;
                    rd_addr <= addr_b;
                    rd_en   <= 1'b1;
                    state   <= FFT_WAIT_B;
                end

                FFT_WAIT_B: begin
                    state <= FFT_LATCH_B;
                end

                FFT_LATCH_B: begin
                    b_re  <= rd_re;
                    b_im  <= rd_im;
                    rd_en <= 1'b0;
                    state <= FFT_MULT;
                end

                FFT_MULT: begin
                    m0 <= b_re * tw_re;
                    m1 <= b_im * tw_im;
                    m2 <= b_re * tw_im;
                    m3 <= b_im * tw_re;
                    state <= FFT_PROD;
                end

                FFT_PROD: begin
                    w0_re <= y0_re;
                    w0_im <= y0_im;
                    w1_re <= y1_re;
                    w1_im <= y1_im;
                    state <= FFT_WR_A;
                end

                FFT_WR_A: begin
                    wr_addr <= addr_a;
                    wr_re   <= w0_re;
                    wr_im   <= w0_im;
                    wr_en   <= 1'b1;
                    state   <= FFT_WR_B;
                end

                FFT_WR_B: begin
                    wr_addr <= addr_b;
                    wr_re   <= w1_re;
                    wr_im   <= w1_im;
                    wr_en   <= 1'b1;

                    if (bf == 10'd511) begin
                        if (stage == 10'd9) begin
                            state <= MAG_SETUP;
                        end else begin
                            stage <= stage + 10'd1;
                            bf    <= 10'd0;
                            state <= FFT_RD_A;
                        end
                    end else begin
                        bf    <= bf + 10'd1;
                        state <= FFT_RD_A;
                    end
                end

                MAG_SETUP: begin
                    mag_idx <= 10'd0;
                    // Issue the synchronous RAM read one cycle early, so
                    // MAG_WAIT sees the current bin before registering its
                    // magnitude. MAG_OUT timing and bin cadence stay intact.
                    rd_addr <= 10'd0;
                    rd_en   <= 1'b1;
                    state   <= MAG_RD;
                end

                MAG_RD: begin
                    rd_addr <= mag_idx;
                    rd_en   <= 1'b1;
                    state   <= MAG_WAIT;
                end

                MAG_WAIT: begin
                    mag_sum_q <= mag_sum;
                    state <= MAG_OUT;
                end

                MAG_OUT: begin
                    bin_index <= mag_idx;
                    bin_mag   <= mag_sum_q;
                    bin_valid <= 1'b1;
                    if (mag_idx == 10'd511) begin
                        frame_valid <= 1'b1;
                        busy        <= 1'b0;
                        if (start_req)
                            result_overrun <= 1'b1;
                        state       <= IDLE;
                    end else begin
                        mag_idx <= mag_idx + 10'd1;
                        rd_addr <= mag_idx + 10'd1;
                        rd_en   <= 1'b1;
                        state   <= MAG_RD;
                    end
                end

                default: state <= IDLE;
            endcase

        end
    end

endmodule
`default_nettype wire
