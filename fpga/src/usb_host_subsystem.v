module usb_host_subsystem #(parameter PORT_ID = 1) (
    input pclk, input uclk, input reset_n,
    input [31:0] paddr, pwdata, input [3:0] pstrb,
    input psel, penable, pwrite,
    output [31:0] prdata, output pready, pslverr,
    inout usb_dp, usb_dn
);
    wire awvalid,wvalid,arvalid,awready,wready,arready,bvalid,rvalid,bready,rready;
    wire [31:0] awaddr,wdata,araddr,rdata;
    wire [3:0] wstrb;
    wire [1:0] bresp,rresp;
    wire [7:0] txdata,rxdata;
    wire txvalid,txready,rxvalid,rxactive,rxerror,termselect,dppull,dmpull;
    wire [1:0] opmode,xcvrselect,linestate;
    wire rxrcv,rxdp,rxdn,txdp,txdn,txoen;
    reg [2:0] preset_sync, reset_sync;
    always @(posedge pclk or negedge reset_n)
        if (!reset_n) preset_sync<=0; else preset_sync<={preset_sync[1:0],1'b1};
    always @(posedge uclk or negedge reset_n)
        if (!reset_n) reset_sync<=0; else reset_sync<={reset_sync[1:0],1'b1};
    wire urst = !reset_sync[2];
    apb_usb_bridge #(.PORT_ID(PORT_ID)) bridge (
        .pclk(pclk),.uclk(uclk),.preset_n(preset_sync[2]),.ureset_n(reset_sync[2]),
        .paddr(paddr),.pwdata(pwdata),.pstrb(pstrb),.psel(psel),.penable(penable),.pwrite(pwrite),
        .diagnostic({23'b0,reset_sync[2],(opmode==2'b10 && xcvrselect==0 && !termselect && dppull && dmpull),linestate,txdn,txdp,txoen,rxdp,rxdn}),
        .prdata(prdata),.pready(pready),.pslverr(pslverr),
        .awvalid(awvalid),.wvalid(wvalid),.arvalid(arvalid),.awaddr(awaddr),.wdata(wdata),.araddr(araddr),
        .wstrb(wstrb),.awready(awready),.wready(wready),.arready(arready),
        .bvalid(bvalid),.rvalid(rvalid),.bresp(bresp),.rresp(rresp),.rdata(rdata),.bready(bready),.rready(rready)
    );
    usbh_host #(.USB_CLK_FREQ(48000000)) host (
        .clk_i(uclk),.rst_i(urst),
        .cfg_awvalid_i(awvalid),.cfg_awaddr_i(awaddr),.cfg_wvalid_i(wvalid),.cfg_wdata_i(wdata),
        .cfg_wstrb_i(wstrb),.cfg_bready_i(bready),.cfg_arvalid_i(arvalid),.cfg_araddr_i(araddr),.cfg_rready_i(rready),
        .cfg_awready_o(awready),.cfg_wready_o(wready),.cfg_bvalid_o(bvalid),.cfg_bresp_o(bresp),
        .cfg_arready_o(arready),.cfg_rvalid_o(rvalid),.cfg_rdata_o(rdata),.cfg_rresp_o(rresp),.intr_o(),
        .utmi_data_in_i(rxdata),.utmi_txready_i(txready),.utmi_rxvalid_i(rxvalid),
        // An idle line error must not poison the
        // following valid packet. Preserve receive errors during packet data;
        // failed SYNC is still rejected through response timeout/PID/CRC checks.
        .utmi_rxactive_i(rxactive),.utmi_rxerror_i(rxerror && rxactive),.utmi_linestate_i(linestate),
        .utmi_data_out_o(txdata),.utmi_txvalid_o(txvalid),.utmi_op_mode_o(opmode),
        .utmi_xcvrselect_o(xcvrselect),.utmi_termselect_o(termselect),
        .utmi_dppulldown_o(dppull),.utmi_dmpulldown_o(dmpull)
    );
    usb_fs_phy phy (
        .clk_i(uclk),.rst_i(urst),.utmi_data_out_i(txdata),.utmi_txvalid_i(txvalid),
        .utmi_op_mode_i(opmode),.utmi_xcvrselect_i(xcvrselect),.utmi_termselect_i(termselect),
        .utmi_dppulldown_i(dppull),.utmi_dmpulldown_i(dmpull),
        .usb_rx_rcv_i(rxrcv),.usb_rx_dp_i(rxdp),.usb_rx_dn_i(rxdn),.usb_reset_assert_i(1'b0),
        .utmi_data_in_o(rxdata),.utmi_txready_o(txready),.utmi_rxvalid_o(rxvalid),
        .utmi_rxactive_o(rxactive),.utmi_rxerror_o(rxerror),.utmi_linestate_o(linestate),
        .usb_tx_dp_o(txdp),.usb_tx_dn_o(txdn),.usb_tx_oen_o(txoen),.usb_reset_detect_o(),.usb_en_o()
    );
    // PHY already produces decoded D+/D-; avoid vendor transceiver mode mux latches.
    assign usb_dp = txoen ? 1'bz : txdp;
    assign usb_dn = txoen ? 1'bz : txdn;
    assign rxdp = usb_dp;
    assign rxdn = usb_dn;
    assign rxrcv = usb_dp && !usb_dn;
endmodule
