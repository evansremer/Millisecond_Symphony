// APB requests are stable in SETUP; capture before the ACCESS response path.
// Peripheral selects use the same byte-address decode as the original top.
module apb_request_capture(
 input clk,reset_n,psel,penable,input [31:0] paddr,pwdata,
 input [3:0] pstrb,input pwrite,
 output reg [31:0] address,data,output reg [3:0] strb,
 output reg write,output reg [6:0] selects,output reg loop_commit_select
);
 always @(posedge clk or negedge reset_n)
 if(!reset_n)begin address<=0;data<=0;strb<=0;write<=0;selects<=0;loop_commit_select<=0;end
 else if(psel && !penable)begin
  address<=paddr;data<=pwdata;strb<=pstrb;write<=pwrite;
  selects[0]<=paddr[23:8]==16'h0002;
  selects[1]<=paddr[23:8]==16'h0003;
  selects[2]<=paddr[23:8]==16'h0004;
  selects[3]<=paddr[23:8]==16'h0005;
  selects[4]<=paddr[23:8]==16'h0006;
  selects[5]<=paddr[23:8]<16'h0002 || paddr[23:8]>16'h0007;
  selects[6]<=paddr[23:8]==16'h0007;
  loop_commit_select<=paddr[23:8]==16'h0006 && paddr[7:0]==8'h10 && pwrite && pstrb==4'hf;
 end
endmodule
