// 50 MHz input -> 71.666667 MHz pixel clock and 358.333333 MHz OSER10 clock.
// The target panel timing is 540 x 2209 total at 60.080 Hz:
// 440 active + 20 HS + 40 HBP + 40 HFP,
// 1920 active + 4 VS + 12 VBP + 273 VFP.
module Gowin_PLL_1080p(
    output wire lock,
    output wire clkout0,
    output wire clkout1,
    input  wire clkin
);
    wire clkout2;
    wire clkout3;
    wire clkout4;
    wire clkout5;
    wire clkout6;
    wire clkfbout;
    wire vcc = 1'b1;
    wire gnd = 1'b0;

    PLL u_pll (
        .LOCK(lock),
        .CLKOUT0(clkout0),
        .CLKOUT1(clkout1),
        .CLKOUT2(clkout2),
        .CLKOUT3(clkout3),
        .CLKOUT4(clkout4),
        .CLKOUT5(clkout5),
        .CLKOUT6(clkout6),
        .CLKFBOUT(clkfbout),
        .CLKIN(clkin),
        .CLKFB(gnd),
        .RESET(gnd),
        .PLLPWD(gnd),
        .RESET_I(gnd),
        .RESET_O(gnd),
        .FBDSEL(6'b000000),
        .IDSEL(6'b000000),
        .MDSEL(6'b000000),
        .MDSEL_FRAC(3'b000),
        .ODSEL0(7'b0000000),
        .ODSEL0_FRAC(3'b000),
        .ODSEL1(7'b0000000),
        .ODSEL2(7'b0000000),
        .ODSEL3(7'b0000000),
        .ODSEL4(7'b0000000),
        .ODSEL5(7'b0000000),
        .ODSEL6(7'b0000000),
        .DT0(4'b0000),
        .DT1(4'b0000),
        .DT2(4'b0000),
        .DT3(4'b0000),
        .ICPSEL(6'b000000),
        .LPFRES(3'b000),
        .LPFCAP(2'b00),
        .PSSEL(3'b000),
        .PSDIR(gnd),
        .PSPULSE(gnd),
        .ENCLK0(vcc),
        .ENCLK1(vcc),
        .ENCLK2(vcc),
        .ENCLK3(vcc),
        .ENCLK4(vcc),
        .ENCLK5(vcc),
        .ENCLK6(vcc),
        .SSCPOL(gnd),
        .SSCON(gnd),
        .SSCMDSEL(6'b000000),
        .SSCMDSEL_FRAC(3'b000)
    );

    defparam u_pll.FCLKIN = "50";
    defparam u_pll.IDIV_SEL = 1;
    defparam u_pll.FBDIV_SEL = 1;
    defparam u_pll.ODIV0_SEL = 15;
    defparam u_pll.ODIV1_SEL = 3;
    defparam u_pll.ODIV2_SEL = 8;
    defparam u_pll.ODIV3_SEL = 8;
    defparam u_pll.ODIV4_SEL = 8;
    defparam u_pll.ODIV5_SEL = 8;
    defparam u_pll.ODIV6_SEL = 8;
    defparam u_pll.MDIV_SEL = 21;
    defparam u_pll.MDIV_FRAC_SEL = 4;
    defparam u_pll.ODIV0_FRAC_SEL = 0;
    defparam u_pll.CLKOUT0_EN = "TRUE";
    defparam u_pll.CLKOUT1_EN = "TRUE";
    defparam u_pll.CLKOUT2_EN = "FALSE";
    defparam u_pll.CLKOUT3_EN = "FALSE";
    defparam u_pll.CLKOUT4_EN = "FALSE";
    defparam u_pll.CLKOUT5_EN = "FALSE";
    defparam u_pll.CLKOUT6_EN = "FALSE";
    defparam u_pll.CLKFB_SEL = "INTERNAL";
    defparam u_pll.CLKOUT0_DT_DIR = 1'b1;
    defparam u_pll.CLKOUT1_DT_DIR = 1'b1;
    defparam u_pll.CLKOUT2_DT_DIR = 1'b1;
    defparam u_pll.CLKOUT3_DT_DIR = 1'b1;
    defparam u_pll.CLKOUT0_DT_STEP = 0;
    defparam u_pll.CLKOUT1_DT_STEP = 0;
    defparam u_pll.CLKOUT2_DT_STEP = 0;
    defparam u_pll.CLKOUT3_DT_STEP = 0;
    defparam u_pll.CLK0_IN_SEL = 1'b0;
    defparam u_pll.CLK0_OUT_SEL = 1'b0;
    defparam u_pll.CLK1_IN_SEL = 1'b0;
    defparam u_pll.CLK1_OUT_SEL = 1'b0;
    defparam u_pll.CLK2_IN_SEL = 1'b0;
    defparam u_pll.CLK2_OUT_SEL = 1'b0;
    defparam u_pll.CLK3_IN_SEL = 1'b0;
    defparam u_pll.CLK3_OUT_SEL = 1'b0;
    defparam u_pll.CLK4_IN_SEL = 2'b00;
    defparam u_pll.CLK4_OUT_SEL = 1'b0;
    defparam u_pll.CLK5_IN_SEL = 1'b0;
    defparam u_pll.CLK5_OUT_SEL = 1'b0;
    defparam u_pll.CLK6_IN_SEL = 1'b0;
    defparam u_pll.CLK6_OUT_SEL = 1'b0;
    defparam u_pll.DYN_DPA_EN = "FALSE";
    defparam u_pll.CLKOUT0_PE_COARSE = 0;
    defparam u_pll.CLKOUT0_PE_FINE = 0;
    defparam u_pll.CLKOUT1_PE_COARSE = 0;
    defparam u_pll.CLKOUT1_PE_FINE = 0;
    defparam u_pll.CLKOUT2_PE_COARSE = 0;
    defparam u_pll.CLKOUT2_PE_FINE = 0;
    defparam u_pll.CLKOUT3_PE_COARSE = 0;
    defparam u_pll.CLKOUT3_PE_FINE = 0;
    defparam u_pll.CLKOUT4_PE_COARSE = 0;
    defparam u_pll.CLKOUT4_PE_FINE = 0;
    defparam u_pll.CLKOUT5_PE_COARSE = 0;
    defparam u_pll.CLKOUT5_PE_FINE = 0;
    defparam u_pll.CLKOUT6_PE_COARSE = 0;
    defparam u_pll.CLKOUT6_PE_FINE = 0;
    defparam u_pll.DYN_PE0_SEL = "FALSE";
    defparam u_pll.DYN_PE1_SEL = "FALSE";
    defparam u_pll.DYN_PE2_SEL = "FALSE";
    defparam u_pll.DYN_PE3_SEL = "FALSE";
    defparam u_pll.DYN_PE4_SEL = "FALSE";
    defparam u_pll.DYN_PE5_SEL = "FALSE";
    defparam u_pll.DYN_PE6_SEL = "FALSE";
    defparam u_pll.DE0_EN = "FALSE";
    defparam u_pll.DE1_EN = "FALSE";
    defparam u_pll.DE2_EN = "FALSE";
    defparam u_pll.DE3_EN = "FALSE";
    defparam u_pll.DE4_EN = "FALSE";
    defparam u_pll.DE5_EN = "FALSE";
    defparam u_pll.DE6_EN = "FALSE";
    defparam u_pll.RESET_I_EN = "FALSE";
    defparam u_pll.RESET_O_EN = "FALSE";
    defparam u_pll.ICP_SEL = 6'bXXXXXX;
    defparam u_pll.LPF_RES = 3'bXXX;
    defparam u_pll.LPF_CAP = 2'b00;
    defparam u_pll.SSC_EN = "FALSE";
    defparam u_pll.DYN_IDIV_SEL = "FALSE";
    defparam u_pll.DYN_FBDIV_SEL = "FALSE";
    defparam u_pll.DYN_MDIV_SEL = "FALSE";
    defparam u_pll.DYN_ODIV0_SEL = "FALSE";
    defparam u_pll.DYN_ODIV1_SEL = "FALSE";
    defparam u_pll.DYN_ODIV2_SEL = "FALSE";
    defparam u_pll.DYN_ODIV3_SEL = "FALSE";
    defparam u_pll.DYN_ODIV4_SEL = "FALSE";
    defparam u_pll.DYN_ODIV5_SEL = "FALSE";
    defparam u_pll.DYN_ODIV6_SEL = "FALSE";
    defparam u_pll.DYN_DT0_SEL = "FALSE";
    defparam u_pll.DYN_DT1_SEL = "FALSE";
    defparam u_pll.DYN_DT2_SEL = "FALSE";
    defparam u_pll.DYN_DT3_SEL = "FALSE";
    defparam u_pll.DYN_ICP_SEL = "FALSE";
    defparam u_pll.DYN_LPF_SEL = "FALSE";
endmodule
