module dvi_tx_top(
    input  wire        pixel_clock,
    input  wire        ddr_bit_clock,
    input  wire        reset,
    input  wire        den,
    input  wire        hsync,
    input  wire        vsync,
    input  wire [23:0] pixel_data,
    output wire [1:0]  tmds_clk,
    output wire [1:0]  tmds_d0,
    output wire [1:0]  tmds_d1,
    output wire [1:0]  tmds_d2
);
    wire [5:0]  ctrl = {4'b0000, vsync, hsync};
    wire [29:0] tmds_encoded;
    wire [1:0]  lane [2:0];

    assign tmds_d0 = lane[0];
    assign tmds_d1 = lane[1];
    assign tmds_d2 = lane[2];

    genvar i;
    generate
        for (i = 0; i < 3; i = i + 1) begin : g_tmds_channel
            dvi_tx_tmds_enc u_encoder (
                .clock (pixel_clock),
                .reset (reset),
                .den   (den),
                .data  (pixel_data[(8*i) +: 8]),
                .ctrl  (ctrl[(2*i) +: 2]),
                .tmds  (tmds_encoded[(10*i) +: 10])
            );

            dvi_tx_tmds_phy u_phy (
                .pixel_clock  (pixel_clock),
                .ddr_bit_clock(ddr_bit_clock),
                .reset        (reset),
                .data         (tmds_encoded[(10*i) +: 10]),
                .tmds_lane    (lane[i])
            );
        end
    endgenerate

    dvi_tx_clk_drv u_clock_phy (
        .pixel_clock (pixel_clock),
        .tmds_clk    (tmds_clk)
    );
endmodule
