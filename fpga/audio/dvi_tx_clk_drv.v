module dvi_tx_clk_drv(
    input  wire       pixel_clock,
    output wire [1:0] tmds_clk
);
    ELVDS_OBUF u_tmds_clock_buf (
        .I  (pixel_clock),
        .O  (tmds_clk[1]),
        .OB (tmds_clk[0])
    );
endmodule
