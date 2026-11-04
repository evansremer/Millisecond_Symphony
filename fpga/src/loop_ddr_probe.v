// Explicit maintenance test, admitted only with EMPTY transport/no saved loop.
// 32 MiB: ascending writes/read, descending read, then permuted write/read
// turnarounds. Two epochs; no audio storage or BSRAM used by this diagnostic.
module loop_ddr_probe #(parameter BITS=20)(
 input clk,reset_n,start,input memory_ready,
 output reg busy,output reg request,write,output reg [28:0] address,output reg [255:0] wdata,
 input ready,response,error,input [255:0] rdata,
 output [191:0] status);
 reg [BITS-1:0] index;reg epoch;reg [2:0] phase;reg [2:0] state;
 reg [31:0] checked,errors,first_bad,max_latency,latency,cycles;
 wire [BITS-1:0] reversed=~index;
 wire [BITS-1:0] permuted=(index*20'd65537)+20'd17;
 wire [BITS-1:0] selected=phase==2?reversed:phase>=3?permuted:index;
 wire [28:0] selected_addr={{(29-BITS-3){1'b0}},selected,3'd0};
 function [255:0] pattern;input [BITS-1:0] ix;input ep;integer lane;
 begin for(lane=0;lane<8;lane=lane+1)pattern[lane*32+:32]=(32'h6d5a0000+32'h1020304*lane)^ix^(ep?32'ha5c39687:32'h37f0182d)^(phase>=3?32'hc9a35e71:32'd0);end
 endfunction
 assign status[31:0]={23'd0,epoch,phase,3'd0,busy,state==7};
 assign status[63:32]=checked;assign status[95:64]=errors;
 assign status[127:96]=first_bad;assign status[159:128]=max_latency;assign status[191:160]=cycles;
 always @(posedge clk or negedge reset_n)
 if(!reset_n)begin busy<=0;request<=0;write<=0;address<=0;wdata<=0;index<=0;epoch<=0;phase<=0;state<=0;checked<=0;errors<=0;first_bad<=32'hffffffff;max_latency<=0;latency<=0;cycles<=0;end
 else begin
  request<=0;
  if(busy)cycles<=cycles+1'b1;
  if(start && !busy && memory_ready)begin busy<=1;index<=0;epoch<=0;phase<=0;state<=1;checked<=0;errors<=0;first_bad<=32'hffffffff;max_latency<=0;cycles<=0;end
  if(busy && !memory_ready)begin busy<=0;errors<=errors+1'b1;state<=7;end
  else case(state)
  1:if(ready)begin write<=phase==0 || phase==3;address<=selected_addr;wdata<=pattern(selected,epoch);request<=1;state<=2;latency<=0;end
  2:begin
   latency<=latency+1'b1;
   if(response)begin
    if(latency>max_latency)max_latency<=latency;
    if(error)begin errors<=errors+1'b1;first_bad<=address;busy<=0;state<=7;end
    else if(phase!=0 && phase!=3 && rdata!=pattern(selected,epoch))begin errors<=errors+1'b1;if(first_bad==32'hffffffff)first_bad<=address;busy<=0;state<=7;end
    else if(phase==3)begin phase<=4;state<=1;end
    else begin
     if(phase!=0)checked<=checked+1'b1;
     if(&index)begin
      index<=0;
      if(phase==4)begin if(epoch)begin busy<=0;state<=7;end else begin epoch<=1;phase<=0;state<=1;end end
      else begin phase<=phase+1'b1;state<=1;end
     end else begin index<=index+1'b1;if(phase==4)phase<=3;state<=1;end
    end
   end
  end
  default:;
  endcase
 end
endmodule
