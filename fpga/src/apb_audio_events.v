// APB -> audio asynchronous FIFO. Full writes fail, never stall USB polling.
// Payload: [31:28] kind 1=on,2=off,3=bend,4=source reset;
// [27] drum source, [26:23] cable, [22:19] channel0, [18:12] note,
// [13:0] bend (kind3), [6:0] velocity (kind1).
module apb_audio_events(
 input pclk,aclk,reset_n,input [7:0] paddr,input [31:0] pwdata,
 input [3:0] pstrb,input psel,penable,pwrite,
 output reg [31:0] prdata,output pready,output pslverr,
 output [31:0] event_data,output event_valid,input event_ready
);
 (* ram_style="block" *) reg [31:0] memory[0:255];
 reg [31:0] read_data;
 reg [8:0] wp,wg,rp,rg;
 reg [8:0] read_pointer_next;
 (* ASYNC_REG="TRUE" *) reg [8:0] rm,rs,wm,ws;
 reg [31:0] rejected;
 wire [8:0] wn=wp+1'b1;
 wire [8:0] wgn=(wn>>1)^wn;
 wire full=(wg=={~rs[8:7],rs[6:0]});
 wire write_event=psel && penable && pwrite && paddr==0;
 assign pready=1'b1;
 assign pslverr=write_event && (full || pstrb!=4'hf);
 assign event_valid=(rg!=ws);
 // Prefetch the next slot on consumption. The Gray pointer synchronizers
 // provide two clocks of settling before a newly written slot becomes valid.
 wire consume_event=event_valid && event_ready;
 wire [8:0] read_pointer=consume_event?read_pointer_next:rp;
 assign event_data=read_data;
 always @(posedge pclk)
  if(reset_n && write_event && !full && pstrb==4'hf)memory[wp[7:0]]<=pwdata;
 always @(posedge aclk)read_data<=memory[read_pointer[7:0]];
 always @* case(paddr)
  8'h04:prdata={30'd0,!full,full};
  8'h08:prdata=rejected;
  8'hf0:prdata=32'h4d410101;
  default:prdata=0;
 endcase
 always @(posedge pclk or negedge reset_n)begin
  if(!reset_n)begin wp<=0;wg<=0;rm<=0;rs<=0;rejected<=0;end
  else begin
   rm<=rg;rs<=rm;
   if(write_event)begin
    if(full || pstrb!=4'hf)rejected<=rejected+1'b1;
    else begin wp<=wn;wg<=wgn;end
   end
  end
 end
 always @(posedge aclk or negedge reset_n)begin
  if(!reset_n)begin rp<=0;rg<=0;read_pointer_next<=1;wm<=0;ws<=0;end
  else begin
   wm<=wg;ws<=wm;
   if(consume_event)begin
    rp<=read_pointer_next;rg<=(read_pointer_next>>1)^read_pointer_next;
    read_pointer_next<=read_pointer_next+1'b1;
   end
  end
 end
endmodule
