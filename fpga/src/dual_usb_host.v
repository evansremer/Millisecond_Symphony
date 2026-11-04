// Two physically independent full-speed USB buses. Both may use USB address 1.
module dual_usb_host (
    input pclk,uclk,reset_n,
    input [31:0] paddr,pwdata, input [3:0] pstrb,
    input psel,penable,pwrite,
    output [31:0] prdata, output pready,pslverr,
    inout usb1_dp,usb1_dn,usb2_dp,usb2_dn
);
    wire select1 = paddr[23:8]==16'h0000;
    wire select2 = paddr[23:8]==16'h0001;
    wire [31:0] local_addr = {24'b0,paddr[7:0]};
    wire [31:0] data1,data2;
    wire ready1,ready2,error1,error2;
    // Unselected PREADY must remain high for AE350 startup (board verified).
    assign pready = !psel ? 1'b1 : select1 ? ready1 : select2 ? ready2 : 1'b1;
    assign prdata = select1 ? data1 : select2 ? data2 : 32'b0;
    assign pslverr = psel && (select1 ? error1 : select2 ? error2 : 1'b1);
    usb_host_subsystem #(.PORT_ID(1)) u_usb1 (
        .pclk(pclk),.uclk(uclk),.reset_n(reset_n),
        .paddr(local_addr),.pwdata(pwdata),.pstrb(pstrb),
        .psel(psel && select1),.penable(penable),.pwrite(pwrite),
        .prdata(data1),.pready(ready1),.pslverr(error1),
        .usb_dp(usb1_dp),.usb_dn(usb1_dn)
    );
    usb_host_subsystem #(.PORT_ID(2)) u_usb2 (
        .pclk(pclk),.uclk(uclk),.reset_n(reset_n),
        .paddr(local_addr),.pwdata(pwdata),.pstrb(pstrb),
        .psel(psel && select2),.penable(penable),.pwrite(pwrite),
        .prdata(data2),.pready(ready2),.pslverr(error2),
        .usb_dp(usb2_dp),.usb_dn(usb2_dn)
    );
endmodule
