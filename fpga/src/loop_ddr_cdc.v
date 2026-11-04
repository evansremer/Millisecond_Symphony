// One outstanding native transaction. Bundled payload remains held until ACK.
// Independent command/data handshakes; fail-closed quarantine on timeout or
// calibration loss. Only board reset releases quarantine (late reads cannot
// become a response to a new transaction). No RAM/FIFO macros.
module loop_ddr_cdc #(parameter TIMEOUT=100000,WRITE_GAP=31)(
 input sclk,dclk,reset_n,calibrated,
 input request,write,input [28:0] address,input [255:0] wdata,
 output ready,output reg response,error,output reg [255:0] rdata,
 output reg fault,
 output [2:0] cmd,output cmd_en,output [28:0] addr,
 output [255:0] wr_data,output wr_en,wr_end,output [31:0] wr_mask,
 input cmd_ready,wr_ready,rd_valid,rd_end,input [255:0] rd_data);
 reg req,ack,busy_s;reg [1:0] ack_meta,req_meta,cal_meta,fault_meta;
 reg held_write;reg [28:0] held_addr;reg [255:0] held_data;
 reg active_write;reg [28:0] active_addr;reg [255:0] active_data,returned;
 reg returned_error,poison;reg [2:0] state;
 localparam TIMER_BITS=TIMEOUT<2?1:$clog2(TIMEOUT);
 localparam GAP_BITS=WRITE_GAP<2?1:$clog2(WRITE_GAP+1);
 reg sent_cmd,sent_data;reg [TIMER_BITS-1:0] timer,stimer;reg [GAP_BITS-1:0] gap;
 assign ready=!busy_s && cal_meta[1] && !fault && reset_n;
 assign cmd=active_write?3'd0:3'd1;assign addr=active_addr;
 assign wr_data=active_data;assign wr_mask=0;
 assign cmd_en=state==2 && !sent_cmd && !poison && calibrated;
 assign wr_en=state==2 && active_write && !sent_data && !poison && calibrated;
 assign wr_end=wr_en;
 wire cd=sent_cmd || (cmd_en && cmd_ready);
 wire wd=sent_data || (wr_en && wr_ready);
 always @(posedge sclk or negedge reset_n)
 if(!reset_n)begin req<=0;ack_meta<=0;cal_meta<=0;fault_meta<=0;busy_s<=0;held_write<=0;held_addr<=0;held_data<=0;response<=0;error<=0;rdata<=0;fault<=0;stimer<=0;end
 else begin
  ack_meta<={ack_meta[0],ack};cal_meta<={cal_meta[0],calibrated};fault_meta<={fault_meta[0],poison};response<=0;
  if(fault_meta[1])fault<=1;
  if(request && ready)begin
   req<=!req;busy_s<=1;held_write<=write;held_addr<=address;held_data<=wdata;stimer<=0;
  end
  if(busy_s)begin
   stimer<=stimer+1'b1;
   if(ack_meta[1]==req)begin busy_s<=0;response<=1;error<=returned_error;rdata<=returned;end
   else if(stimer==TIMEOUT-1 || fault_meta[1])begin busy_s<=0;response<=1;error<=1;fault<=1;end
  end
 end
 always @(posedge dclk or negedge reset_n)
 if(!reset_n)begin req_meta<=0;ack<=0;active_write<=0;active_addr<=0;active_data<=0;returned<=0;returned_error<=0;poison<=0;state<=0;sent_cmd<=0;sent_data<=0;timer<=0;gap<=0;end
 else begin
  req_meta<={req_meta[0],req};
  if(state!=0 && state!=4 && !calibrated)begin poison<=1;state<=5;returned_error<=1;ack<=req_meta[1];end
  else if(state>=1 && state<=3 && timer==TIMEOUT-1)begin poison<=1;state<=5;returned_error<=1;ack<=req_meta[1];end
  else begin
   if(state>=1 && state<=3)timer<=timer+1'b1;
   case(state)
   0:if(req_meta[1]!=ack && calibrated && !poison)begin timer<=0;state<=1;end
   1:begin active_write<=held_write;active_addr<=held_addr;active_data<=held_data;sent_cmd<=0;sent_data<=0;returned_error<=0;state<=2;end
   2:begin
    if(cmd_en && cmd_ready)sent_cmd<=1;
    if(wr_en && wr_ready)sent_data<=1;
    if(cd && (!active_write || wd))begin
     if(active_write)begin gap<=WRITE_GAP;state<=4;end
     else if(rd_valid)begin returned<=rd_data;returned_error<=!rd_end;ack<=req_meta[1];state<=0;end
     else state<=3;
    end
   end
   3:if(rd_valid)begin returned<=rd_data;returned_error<=!rd_end;ack<=req_meta[1];state<=0;end
   4:if(!calibrated)begin poison<=1;returned_error<=1;ack<=req_meta[1];state<=5;end
     else if(gap==0)begin ack<=req_meta[1];state<=0;end else gap<=gap-1'b1;
   default:;
   endcase
  end
 end
endmodule
