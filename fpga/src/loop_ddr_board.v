// Isolated board DDR clock/PHY; never drives the AE350 hard-core DDR port.
module loop_ddr_board(input sys_clk,reset_n,aclk,diagnostic_start,output [191:0] diagnostic_status,
 input request,write,input [28:0] address,input [255:0] wdata,
 output ready,response,error,output [255:0] rdata,output memory_ready,fault,
 output [14:0] ddr_addr,output [2:0] ddr_bank,
 output ddr_cs,ddr_ras,ddr_cas,ddr_we,ddr_ck,ddr_ck_n,ddr_cke,ddr_odt,ddr_reset_n,
 output [3:0] ddr_dm,inout [31:0] ddr_dq,inout [3:0] ddr_dqs,ddr_dqs_n);
 reg [23:0] startup=0;reg powered=0;
 always @(posedge sys_clk or negedge reset_n)
 if(!reset_n)begin startup<=0;powered<=0;end
 else if(!powered)begin if(startup==9999999)powered<=1;else startup<=startup+1'b1;end
 wire memory_clk,ui_clk,pll_lock,pll_stop,calibrated;
 Loop_DDR_PLL pll(.clkin(sys_clk),.init_clk(sys_clk),.reset(!powered),.enclk0(1'b1),.enclk1(1'b1),.enclk2(pll_stop),.clkout0(),.clkout1(),.clkout2(memory_clk),.lock(pll_lock));
 reg [1:0] cal_meta;
 always @(posedge aclk or negedge reset_n)
 if(!reset_n)cal_meta<=0;else cal_meta<={cal_meta[0],calibrated};
 wire bridge_poison;
 reg [25:0] calibration_timer;reg calibration_failed,seen_cal;
 reg [1:0] cal_sys,failed_audio;
 always @(posedge sys_clk or negedge reset_n)
 if(!reset_n)begin calibration_timer<=0;calibration_failed<=0;cal_sys<=0;seen_cal<=0;end
 else begin
  cal_sys<={cal_sys[0],calibrated};
  if(cal_sys[1])seen_cal<=1;
  if(powered && !cal_sys[1])begin
   if(calibration_timer==49999999 || seen_cal)calibration_failed<=1;
   else calibration_timer<=calibration_timer+1'b1;
  end
 end
 always @(posedge aclk or negedge reset_n)
 if(!reset_n)failed_audio<=0;else failed_audio<={failed_audio[0],calibration_failed};
 assign fault=bridge_poison || failed_audio[1];
 wire diagnostic_busy,diag_request,diag_write,bus_ready,bus_response,bus_error;
 wire [28:0] diag_address;wire [255:0] diag_data,bus_data;
 wire physical_ready=cal_meta[1] && !fault;
 assign memory_ready=physical_ready && !diagnostic_busy;
 assign ready=bus_ready && !diagnostic_busy;
 assign response=bus_response && !diagnostic_busy;
 assign error=bus_error;assign rdata=bus_data;
 loop_ddr_probe probe(.clk(aclk),.reset_n(reset_n),.start(diagnostic_start),.memory_ready(physical_ready),
  .busy(diagnostic_busy),.request(diag_request),.write(diag_write),.address(diag_address),.wdata(diag_data),
  .ready(bus_ready),.response(bus_response),.error(bus_error),.rdata(bus_data),.status(diagnostic_status));
 wire [2:0] cmd;wire cmd_en,wr_en,wr_end,cmd_ready,wr_ready,rd_valid,rd_end;
 wire [28:0] addr;wire [255:0] wd,rd;wire [31:0] mask;
 loop_ddr_cdc bridge(.sclk(aclk),.dclk(ui_clk),.reset_n(reset_n),.calibrated(calibrated),
  .request(diagnostic_busy?diag_request:request),.write(diagnostic_busy?diag_write:write),.address(diagnostic_busy?diag_address:address),.wdata(diagnostic_busy?diag_data:wdata),
  .ready(bus_ready),.response(bus_response),.error(bus_error),.rdata(bus_data),.fault(bridge_poison),
  .cmd(cmd),.cmd_en(cmd_en),.addr(addr),.wr_data(wd),.wr_en(wr_en),.wr_end(wr_end),.wr_mask(mask),
  .cmd_ready(cmd_ready),.wr_ready(wr_ready),.rd_valid(rd_valid),.rd_end(rd_end),.rd_data(rd));
 Tang_DDR_B_400 phy(.memory_clk(memory_clk),.pll_stop(pll_stop),.clk(sys_clk),.rst_n(powered),
  .cmd_ready(cmd_ready),.cmd(cmd),.cmd_en(cmd_en),.addr(addr),.wr_data_rdy(wr_ready),.wr_data(wd),.wr_data_en(wr_en),.wr_data_end(wr_end),.wr_data_mask(mask),
  .rd_data(rd),.rd_data_valid(rd_valid),.rd_data_end(rd_end),.sr_req(1'b0),.ref_req(1'b0),.sr_ack(),.ref_ack(),
  .init_calib_complete(calibrated),.clk_out(ui_clk),.pll_lock(pll_lock),.burst(1'b0),.ddr_rst(),
  .O_ddr_addr(ddr_addr),.O_ddr_ba(ddr_bank),.O_ddr_cs_n(ddr_cs),.O_ddr_ras_n(ddr_ras),.O_ddr_cas_n(ddr_cas),.O_ddr_we_n(ddr_we),
  .O_ddr_clk(ddr_ck),.O_ddr_clk_n(ddr_ck_n),.O_ddr_cke(ddr_cke),.O_ddr_odt(ddr_odt),.O_ddr_reset_n(ddr_reset_n),.O_ddr_dqm(ddr_dm),
  .IO_ddr_dq(ddr_dq),.IO_ddr_dqs(ddr_dqs),.IO_ddr_dqs_n(ddr_dqs_n));
endmodule
