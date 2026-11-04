// CPU command mailbox and coherent telemetry. FPGA state is authoritative.
module apb_loop(input pclk,aclk,reset_n,sample_ce,
 input [7:0] paddr,input [31:0] pwdata,input [3:0] pstrb,input psel,penable,pwrite,input commit_select,
 output reg [31:0] prdata,output pready,pslverr,
 output [127:0] command,output command_valid,input [511:0] status,input [191:0] diagnostic);
 reg [127:0] stage;wire busy;wire [15:0] applied;
 wire wr=psel&&penable&&pwrite,rd=psel&&penable&&!pwrite;
 wire commit=wr && commit_select && !busy;
 console_mailbox #(.WIDTH(128),.INITIAL(128'd0)) mb(.sclk(pclk),.dclk(aclk),.reset_n(reset_n),
  .staged(stage),.commit(commit),.busy(busy),.apply(sample_ce),.data(command),.applied_seq(applied));
 reg [15:0] seen;
 assign command_valid=applied!=seen;
 always @(posedge aclk or negedge reset_n)if(!reset_n)seen<=0;else seen<=applied;
 wire [703:0] synchronized;wire snap_valid;
 touch_snapshot_cdc #(.WIDTH(704),.CHANGE_ONLY(0)) telemetry(.sclk(aclk),.dclk(pclk),.reset_n(reset_n),.source({diagnostic,status}),.snapshot(synchronized),.valid(snap_valid));
 reg [703:0] frozen;reg [4:0] index;reg waiting;reg [31:0] data;
 always @(posedge pclk)data<=frozen[index*32+:32];
 assign pready=!(rd && paddr==8'h28 && waiting);
 assign pslverr=wr && (pstrb!=15 || !((paddr>=8'h40 && paddr<=8'h4c)||paddr==8'h10||paddr==8'h20||paddr==8'h24) || (paddr==8'h10 && busy));
 always @*case(paddr)
  0:prdata=32'h4c500100;
  4:prdata={30'd0,snap_valid,busy};
  8:prdata=32'd2304000;
  8'h28:prdata=data;
  default:prdata=0;
 endcase
 always @(posedge pclk or negedge reset_n)
 if(!reset_n)begin stage<=0;frozen<=0;index<=0;waiting<=0;end
 else begin
  waiting<=0;
  if(wr && pstrb==15)begin
   if(paddr>=8'h40 && paddr<=8'h4c)stage[paddr[3:2]*32+:32]<=pwdata;
   if(paddr==8'h20)begin frozen<=synchronized;waiting<=1;end
   if(paddr==8'h24)begin index<=pwdata[4:0];waiting<=1;end
  end
 end
endmodule
