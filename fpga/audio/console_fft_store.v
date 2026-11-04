// Three raw-bin banks: frozen display never stalls the FFT producer.
// Ownership metadata is held with the request/ACK; no asynchronous bank mux.
module console_fft_store(
 input aclk,uclk,reset_n,input wr_valid,input [8:0] wr_index,input [23:0] wr_data,
 input frame_tick,freeze,input [8:0] read_index,output reg [23:0] read_data,
 output reg have_frame,output reg dropped
);
 (* syn_ramstyle="block_ram" *)reg [23:0] memory[0:1535];
 reg [1:0] write_bank,published,active;
 reg request,ack,collect;
 (* ASYNC_REG="TRUE" *)reg [1:0] ack_sync,req_sync;
 reg [1:0] active_held;
 wire [1:0] free_bank=(published!=0 && active_held!=0)?0:
                            (published!=1 && active_held!=1)?1:2;
 reg [10:0] write_addr;
 wire start=wr_valid && wr_index==0 && request==ack_sync[1];
 always @* write_addr={write_bank,9'd0}+wr_index;
 always @(posedge aclk)begin
  if(reset_n && wr_valid)begin
   if(start)memory[{free_bank,9'd0}]<=wr_data;
   else if(collect)memory[write_addr]<=wr_data;
  end
 end
 always @(posedge aclk or negedge reset_n)begin
  if(!reset_n)begin write_bank<=1;published<=0;request<=0;ack_sync<=0;collect<=0;dropped<=0;end
  else begin
   ack_sync<={ack_sync[0],ack};
   if(wr_valid && wr_index==0)begin
    collect<=request==ack_sync[1];
    if(start)write_bank<=free_bank;else dropped<=1;
   end
   if(wr_valid && wr_index==511 && collect)begin published<=write_bank;request<=~request;collect<=0;end
  end
 end
 always @(posedge uclk)begin
  if(!reset_n)begin active<=0;active_held<=0;ack<=0;req_sync<=0;read_data<=0;have_frame<=0;end
  else begin
   req_sync<={req_sync[0],request};
   if(frame_tick && req_sync[1]!=ack)begin
    ack<=req_sync[1];
    if(!freeze || !have_frame)begin active<=published;active_held<=published;have_frame<=1;end
   end
   read_data<=have_frame?memory[{active,9'd0}+read_index]:24'd0;
  end
 end
endmodule
