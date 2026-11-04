// Layout verified against the captured 413d:2107 report descriptor, SHA256
// f21f8c7fb2dfdd95f61c44dcda473d7c36d36258c89472c5e39b9e8f21795109.
// Report ID 1: six 8-byte finger slots, scan time, contact count (52 bytes).
module hid_413d_touch(
 input clk,rst,profile_ok,trace_valid,input [31:0] trace_data,
 output reg touch_valid,touch_down,output reg [11:0] touch_x,touch_y,
 output reg [7:0] contacts,output reg [23:0] accepted,rejected
);
 reg [7:0] bytes[0:51];reg receiving;reg [6:0] seen;reg [15:0] seq;
 reg owner_valid,suppress_rearm;reg [7:0] owner_id,selected_id;reg any_contact;
 integer k;reg found;reg [15:0] raw_x,raw_y;reg [31:0] scaled_x,scaled_y;
 always @* begin
  found=0;raw_x=0;raw_y=0;selected_id=0;any_contact=0;
  for(k=0;k<6;k=k+1) begin
   if(bytes[1+8*k][0])any_contact=1;
   if(!found && !suppress_rearm && bytes[1+8*k][0] && (!owner_valid || bytes[2+8*k]==owner_id)) begin
    selected_id=bytes[2+8*k];found=1;raw_x={bytes[4+8*k],bytes[3+8*k]};raw_y={bytes[6+8*k],bytes[5+8*k]};
   end
  end
  // Exact logical maximum from the actual descriptor: 2048 inclusive.
  scaled_x=(raw_x>2048)?439:(raw_x*32'd439)>>11;
  scaled_y=(raw_y>2048)?1919:(raw_y*32'd1919)>>11;
 end
 always @(posedge clk) begin
  if(rst) begin receiving<=0;seen<=0;seq<=0;touch_valid<=0;touch_down<=0;
   owner_valid<=0;suppress_rearm<=0;owner_id<=0;touch_x<=0;touch_y<=0;contacts<=0;accepted<=0;rejected<=0;
  end else begin
   touch_valid<=0;
   if(!profile_ok) begin receiving<=0;touch_down<=0;owner_valid<=0;suppress_rearm<=0;end
   else if(trace_valid) case(trace_data[31:24])
   8'h80: begin receiving<=trace_data[7:0]==52;seq<=trace_data[23:8];seen<=0;end
   8'h81: if(receiving) begin
    if(trace_data[23:8]==seen && seen<52) begin bytes[seen]<=trace_data[7:0];seen<=seen+1'b1;end
    else begin receiving<=0;rejected<=rejected+1'b1;end
   end
   8'h82: if(receiving) begin
    receiving<=0;
    if(trace_data[23:8]==seq && seen==52 && bytes[0]==1 && bytes[51]<=6 &&
       (!found || (raw_x<=2048 && raw_y<=2048))) begin
     if(!any_contact || bytes[51]==0)begin owner_valid<=0;suppress_rearm<=0;end
     else if(owner_valid && !found)begin owner_valid<=0;suppress_rearm<=1;end
     else if(found)begin owner_valid<=1;owner_id<=selected_id;end
     touch_valid<=1;touch_down<=found && bytes[51]!=0;contacts<=bytes[51];accepted<=accepted+1'b1;
     if(found && bytes[51]!=0) begin touch_x<=scaled_x[11:0];touch_y<=scaled_y[11:0];end
    end else rejected<=rejected+1'b1;
   end
   default: ;
   endcase
  end
 end
endmodule
