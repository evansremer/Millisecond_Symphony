// Latest-state mailbox. Held data changes only when the previous copy is ACKed.
// Fast source updates coalesce; the eventual release is never lost.
module touch_snapshot_cdc #(parameter WIDTH=28,parameter CHANGE_ONLY=1)(
 input sclk,dclk,reset_n,
 input [WIDTH-1:0] source,
 output reg [WIDTH-1:0] snapshot,
 output reg valid
);
 reg [WIDTH-1:0] held;
 reg request,ack;
 // Assertion is common and asynchronous; each domain releases locally.
 (* ASYNC_REG="TRUE" *) reg [1:0] source_reset_sync,sink_reset_sync;
 always @(posedge sclk or negedge reset_n)
  if(!reset_n)source_reset_sync<=0;
  else source_reset_sync<={source_reset_sync[0],1'b1};
 always @(posedge dclk or negedge reset_n)
  if(!reset_n)sink_reset_sync<=0;
  else sink_reset_sync<={sink_reset_sync[0],1'b1};
 wire source_reset_n=source_reset_sync[1];
 wire sink_reset_n=sink_reset_sync[1];
 (* ASYNC_REG="TRUE" *) reg ack_meta,ack_sync,request_meta,request_sync;
 always @(posedge sclk or negedge source_reset_n) begin
  if(!source_reset_n)begin held<=0;request<=0;ack_meta<=0;ack_sync<=0;end
  else begin
   ack_meta<=ack;ack_sync<=ack_meta;
   if(request==ack_sync && (!CHANGE_ONLY || held!=source))begin held<=source;request<=~request;end
  end
 end
 always @(posedge dclk or negedge sink_reset_n)begin
  if(!sink_reset_n)begin snapshot<=0;valid<=0;ack<=0;request_meta<=0;request_sync<=0;end
  else begin
   request_meta<=request;request_sync<=request_meta;valid<=0;
   if(request_sync!=ack)begin snapshot<=held;ack<=request_sync;valid<=1;end
  end
 end
endmodule
