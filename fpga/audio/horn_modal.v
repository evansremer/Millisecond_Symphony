// Eight damped complex IIR states per voice: two opposite-sign resonators per
// fitted attack mode give its finite-rise burst. Shared pipelined arithmetic.
module horn_modal(
input wire clk,rst_n,start,
input wire [15:0] active,strike,
input wire [287:0] voice_ratios,
input wire [111:0] parameter_ids,
input wire [1199:0] releases,
input wire [287:0] velocity_gains,
output reg done,overflow,
output reg signed [35:0] sum
);
(* rom_style="block" *) reg [103:0] params[0:1023];
(* ram_style="block" *) reg [47:0] states[0:127];
reg [103:0] pq;reg [47:0] sq;
wire signed [32:0] angle_q=0;

wire [97:0] pitched_payload;
wire pitched_valid;wire signed [27:0] pitched_a,pitched_b;
reg [24:0] release_delay[0:9];reg [17:0] velocity_delay[0:9];
wire [6:0] parameter_words[0:15];
wire [24:0] release_words[0:15];
wire [17:0] velocity_words[0:15];
genvar g;
generate for(g=0;g<16;g=g+1)begin:unpack_words
 assign parameter_words[g]=parameter_ids[g*7 +:7];
 assign release_words[g]=releases[g*75+25 +:25];
 assign velocity_words[g]=velocity_gains[g*18 +:18];
end endgenerate
reg issuing;reg [6:0] address;reg [9:0] valid;
reg [6:0] tag[0:9];
wire [9:0] pa={parameter_words[address[6:3]],address[2:0]};
wire [3:0] v0=tag[0][6:3],v3=tag[3][6:3],v5=tag[5][6:3],v7=tag[7][6:3];
wire signed [23:0] initial_r=!active[v0]?24'sd0:(strike[v0]?$signed(pq[79:56]):$signed(sq[23:0]));
wire signed [23:0] initial_i=!active[v0]?24'sd0:(strike[v0]?$signed(pq[103:80]):$signed(sq[47:24]));
midi_pitch_rotate #(.PAYLOAD_BITS(98)) bend(
 .clk(clk),.rst_n(rst_n),.in_valid(valid[0]),.a(pq[27:0]),.b(pq[55:28]),.angle(angle_q),
 .ratio(voice_ratios[v0*18+:18]),.payload({tag[0],release_words[v0],velocity_words[v0],initial_r,initial_i}),
 .out_valid(pitched_valid),.out_a(pitched_a),.out_b(pitched_b),.out_payload(pitched_payload));
reg signed [23:0] xr0,xi0,xr1,xr2;
reg signed [27:0] a0,b0;
reg signed [51:0] rr1,ii1,ri1,ir1;
reg signed [52:0] nr2,ni2;
reg signed [23:0] nr3,ni3;
reg signed [49:0] release3;
reg signed [23:0] weighted4;
reg signed [42:0] velocity5;
reg signed [35:0] contribution6,contribution7,contribution8,accum;
wire signed [52:0] rounded_r=(nr2+53'sd33554432)>>>26;
wire signed [52:0] rounded_i=(ni2+53'sd33554432)>>>26;
function signed [23:0] sat24;
input signed [52:0] x;
begin if(x>8388607)sat24=24'sh7fffff;else if(x< -8388608)sat24=24'sh800000;else sat24=x[23:0];end
endfunction
integer j;
initial $readmemh("horn_modal.mem",params);
always @(posedge clk)begin
 if(issuing)begin pq<=params[pa];sq<=states[address];end
 if(pitched_valid)begin
   xr0<=pitched_payload[47:24];xi0<=pitched_payload[23:0];
   a0<=pitched_a;b0<=pitched_b;
 end
 if(valid[1])begin rr1<=xr0*a0;ii1<=xi0*b0;ri1<=xr0*b0;ir1<=xi0*a0;xr1<=xr0;end
 if(valid[2])begin nr2<=$signed(rr1)-$signed(ii1);ni2<=$signed(ri1)+$signed(ir1);xr2<=xr1;end
 if(valid[3])begin
   nr3<=sat24(rounded_r);ni3<=sat24(rounded_i);
   release3<=xr2*$signed({1'b0,release_delay[3]});
 end
 if(valid[4])begin states[tag[4]]<={ni3,nr3};weighted4<=release3>>>24;end
 if(valid[5])velocity5<=weighted4*$signed({1'b0,velocity_delay[5]});
 if(valid[6])contribution6<=velocity5>>>22;
 if(valid[7])contribution7<=contribution6;
 if(valid[8])contribution8<=contribution7;
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin issuing<=0;address<=0;valid<=0;done<=0;overflow<=0;sum<=0;accum<=0;
   for(j=0;j<10;j=j+1)tag[j]<=0;
 end else begin
   done<=0;valid[0]<=issuing;tag[0]<=address;
   valid[1]<=pitched_valid;tag[1]<=pitched_payload[97:91];
   release_delay[1]<=pitched_payload[90:66];velocity_delay[1]<=pitched_payload[65:48];
   for(j=2;j<10;j=j+1)begin valid[j]<=valid[j-1];tag[j]<=tag[j-1];release_delay[j]<=release_delay[j-1];velocity_delay[j]<=velocity_delay[j-1];end

   if(start)begin issuing<=1;address<=0;accum<=0;end
   else if(issuing)begin if(address==127)issuing<=0;else address<=address+1'b1;end
   if(valid[3] && (rounded_r>8388607 || rounded_r< -8388608 || rounded_i>8388607 || rounded_i< -8388608))overflow<=1;
   if(valid[9])begin
     accum<=accum+contribution8;
     if(tag[9]==127)begin sum<=accum+contribution8;done<=1;end
   end
 end
end
endmodule
