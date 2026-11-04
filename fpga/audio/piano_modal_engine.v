// 512 modal lanes/frame, II=1; pitch rotation adds 26 clocks per frame.
module piano_modal_engine #(parameter PARAM_FILE="piano_modal.mem")(
 input clk,rst_n,start,input [15:0] active,gate,strike,fresh,settled,
 input [79:0] key_bus,velocity_bus,input [111:0] damp_bus,
 input [287:0] voice_ratios,
 output reg busy,done,overflow,output reg signed [39:0] sum,output reg [15:0] quiet
);
 `include "piano_math.vh"
 (* rom_style="block" *) reg [163:0] params[0:1023];
 (* ram_style="block" *) reg [47:0] states[0:511];
 reg [163:0] pq;wire signed [32:0] angle1=0;
 reg [47:0] sq;reg issuing;reg [8:0] address;
 reg [2:0] valid;reg [8:0] tag[0:2];
 wire [9:0] pa={key_bus[address[8:5]*5+:5],address[4:0]};
 wire [3:0] v0=tag[0][8:5],v1=tag[1][8:5],v2=tag[2][8:5];
 reg signed [23:0] old_r,old_i,exc_r,exc_i,gain0,gain1;
 reg signed [27:0] hold_a,hold_b;
 reg signed [31:0] step_a,step_b;
 reg signed [24:0] add_r,add_i;
 reg signed [28:0] ca,cb;
 wire signed [23:0] xr=p_sat24(add_r),xi=p_sat24(add_i);
 wire silent=!active[v2] || (settled[v2] && (p_abs24(xr)+p_abs24(xi))<16);
 wire [81:0] payload={tag[2],gate[v2],silent?24'd0:xr,silent?24'd0:xi,gain1};
 wire [81:0] rotated_payload;wire rv;wire signed [27:0] ra,rb;
 midi_pitch_rotate #(.PAYLOAD_BITS(82)) bend(
  .clk(clk),.rst_n(rst_n),.in_valid(valid[2]),.a(ca[27:0]),.b(cb[27:0]),.angle(angle1),
  .ratio(voice_ratios[v2*18+:18]),.payload(payload),.out_valid(rv),.out_a(ra),.out_b(rb),.out_payload(rotated_payload));
 wire signed [23:0] rx=rotated_payload[71:48],ix=rotated_payload[47:24],gx=rotated_payload[23:0];
 reg [2:0] tail_valid;reg [8:0] tail_tag[0:2];reg [2:0] tail_gate;
 reg signed [51:0] rr,ii,ri,ir;reg signed [47:0] weight;
 reg signed [52:0] nr,ni;
 reg signed [39:0] weighted,contribution,accumulator;
 reg signed [23:0] next_r,next_i;
 wire signed [52:0] rounded_r=tail_gate[1]?p_round(nr,26):p_trunc(nr,26);
 wire signed [52:0] rounded_i=tail_gate[1]?p_round(ni,26):p_trunc(ni,26);
 integer k;
 initial begin $readmemh(PARAM_FILE,params);end
 always @(posedge clk)begin
  if(issuing)begin pq<=params[pa];sq<=states[address];end
  if(valid[0])begin
   old_r<=active[v0] && !fresh[v0]?$signed(sq[23:0]):24'sd0;
   old_i<=active[v0] && !fresh[v0]?$signed(sq[47:24]):24'sd0;
   exc_r<=$signed(pq[121:104])*$signed({1'b0,velocity_bus[v0*5+:5]});
   exc_i<=$signed(pq[139:122])*$signed({1'b0,velocity_bus[v0*5+:5]});
   hold_a<=pq[27:0];hold_b<=pq[55:28];
   step_a<=$signed(pq[79:56])*$signed({1'b0,damp_bus[v0*7+:7]});
   step_b<=$signed(pq[103:80])*$signed({1'b0,damp_bus[v0*7+:7]});
   gain0<=pq[163:140];
  end
  if(valid[1])begin
   add_r<=$signed(old_r)+(strike[v1]?$signed(exc_r):24'sd0);
   add_i<=$signed(old_i)+(strike[v1]?$signed(exc_i):24'sd0);
   ca<=$signed(hold_a)+p_round(step_a,8);cb<=$signed(hold_b)+p_round(step_b,8);
   gain1<=gain0;
  end
  if(rv)begin rr<=rx*ra;ii<=ix*rb;ri<=rx*rb;ir<=ix*ra;weight<=rx*gx;end
  if(tail_valid[0])begin
   nr<=$signed({rr[51],rr})-$signed({ii[51],ii});ni<=$signed({ri[51],ri})+$signed({ir[51],ir});weighted<=p_round(weight,21);
  end
  if(tail_valid[1])begin next_r<=p_sat24(rounded_r);next_i<=p_sat24(rounded_i);contribution<=weighted;end
  if(tail_valid[2])states[tail_tag[2]]<={next_i,next_r};
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   busy<=0;done<=0;overflow<=0;sum<=0;quiet<=16'hffff;issuing<=0;address<=0;valid<=0;tail_valid<=0;tail_gate<=0;accumulator<=0;
   for(k=0;k<3;k=k+1)begin tag[k]<=0;tail_tag[k]<=0;end
  end else begin
   done<=0;valid<={valid[1:0],issuing};tag[0]<=address;tag[1]<=tag[0];tag[2]<=tag[1];
   tail_valid<={tail_valid[1:0],rv};tail_gate<={tail_gate[1:0],rotated_payload[72]};
   tail_tag[0]<=rotated_payload[81:73];tail_tag[1]<=tail_tag[0];tail_tag[2]<=tail_tag[1];
   if(start)begin
    accumulator<=0;quiet<=16'hffff;address<=0;
    if(active==0)begin sum<=0;done<=1;busy<=0;end else begin issuing<=1;busy<=1;end
   end else if(issuing)begin if(address==511)issuing<=0;else address<=address+1'b1;end
   if(valid[2] && (p_clip24(add_r)||p_clip24(add_i)))overflow<=1;
   if(tail_valid[1] && (p_clip24(rounded_r)||p_clip24(rounded_i)))overflow<=1;
   if(tail_valid[2])begin
    if(next_r!=0 || next_i!=0)quiet[tail_tag[2][8:5]]<=0;
    accumulator<=accumulator+contribution;
    if(tail_tag[2]==511)begin sum<=accumulator+contribution;busy<=0;done<=1;end
   end
  end
 end
endmodule
