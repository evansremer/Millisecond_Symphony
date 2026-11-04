module dvi_tx_tmds_phy(
    input  wire       pixel_clock,
    input  wire       ddr_bit_clock,
    input  wire       reset,
    input  wire [9:0] data,
    output wire [1:0] tmds_lane
);
    reg  reset_reg;
    wire serial_data;

    always @(posedge pixel_clock)
        reset_reg <= reset;

    OSER10 u_serializer (
        .Q     (serial_data),
        .D0    (data[0]),
        .D1    (data[1]),
        .D2    (data[2]),
        .D3    (data[3]),
        .D4    (data[4]),
        .D5    (data[5]),
        .D6    (data[6]),
        .D7    (data[7]),
        .D8    (data[8]),
        .D9    (data[9]),
        .PCLK  (pixel_clock),
        .FCLK  (ddr_bit_clock),
        .RESET (reset_reg)
    );

    ELVDS_OBUF u_tmds_data_buf (
        .I  (serial_data),
        .O  (tmds_lane[1]),
        .OB (tmds_lane[0])
    );
endmodule
