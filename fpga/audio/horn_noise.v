// Four unit-RMS bandpass IIRs per voice, with independent fitted burst+air gains.
// ROM gains already contain the user-approved 0.5 (-6.02 dB) noise reduction.
module horn_noise(
input wire clk,rst_n,start,
input wire [15:0] active,strike,
input wire [111:0] parameter_ids,
input wire [863:0] envelopes,
input wire [1199:0] releases,
input wire [399:0] transients,
input wire [287:0] velocity_gains,
input wire [383:0] whites,
output reg done,overflow,
output reg signed [35:0] sum
);
(* rom_style="block" *) reg [123:0] params[0:511];
(* ram_style="distributed" *) reg [47:0] states[0:63];
reg [123:0] pq;reg [47:0] sq;
wire [6:0] parameter_words[0:15];
wire [24:0] release_words[0:15],transient_words[0:15];
wire [17:0] envelope_words[0:15],velocity_words[0:15];
wire [23:0] white_words[0:15];
genvar g;
generate for(g=0;g<16;g=g+1)begin:unpack_words
 assign parameter_words[g]=parameter_ids[g*7 +:7];
 assign release_words[g]=releases[g*75+50 +:25];
 assign transient_words[g]=transients[g*25 +:25];
 assign envelope_words[g]=envelopes[g*54+18 +:18];
 assign velocity_words[g]=velocity_gains[g*18 +:18];
 assign white_words[g]=whites[g*24 +:24];
end endgenerate
reg issuing;reg [5:0] address;reg [10:0] valid;reg [5:0] tag[0:10];
wire [8:0] pa={parameter_words[address[5:2]],address[1:0]};
wire [3:0] v0=tag[0][5:2],v5=tag[5][5:2],v7=tag[7][5:2];
reg signed [23:0] d10,d20,d21,d22,d23;
reg signed [27:0] a10,a20,a11,a21,a12,a22;
reg signed [51:0] ip0,ip1,ip2,ip3;
reg [44:0] attack0;reg [37:0] sustain0;
reg signed [20:0] gain1,gain2;
reg signed [52:0] fwide1,d1wide4,d2wide4;
reg signed [23:0] filtered2,weighted4,nd15,nd25,weighted6;
reg signed [51:0] feedback13,feedback23;
reg signed [44:0] weighted3;
reg signed [49:0] release5;
reg signed [42:0] velocity7;
reg signed [35:0] contribution8,contribution9,accum;
wire signed [52:0] rounded_f=(fwide1+53'sd33554432)>>>26;
wire signed [52:0] rounded_d1=(d1wide4+53'sd33554432)>>>26;
wire signed [52:0] rounded_d2=(d2wide4+53'sd33554432)>>>26;
function signed [23:0] sat24;
input signed [52:0] x;
begin if(x>8388607)sat24=24'sh7fffff;else if(x< -8388608)sat24=24'sh800000;else sat24=x[23:0];end
endfunction
integer j;
initial $readmemh("horn_noise.mem",params);
always @(posedge clk)begin
 if(issuing)begin pq<=params[pa];sq<=states[address];end
 if(valid[0])begin
   ip0<=$signed(pq[27:0])*$signed(white_words[v0]);
   a10<=pq[55:28];a20<=pq[83:56];
   d10<=(!active[v0] || strike[v0])?24'sd0:$signed(sq[23:0]);
   d20<=(!active[v0] || strike[v0])?24'sd0:$signed(sq[47:24]);
   attack0<=pq[103:84]*transient_words[v0];
   sustain0<=pq[123:104]*envelope_words[v0];
 end
 if(valid[1])begin
   fwide1<=$signed(ip0)+($signed({{29{d10[23]}},d10})<<<26);
   gain1<=$signed(attack0>>24)+$signed(sustain0>>16);
   ip1<=ip0;d21<=d20;a11<=a10;a21<=a20;
 end
 if(valid[2])begin
   filtered2<=sat24(rounded_f);gain2<=gain1;
   ip2<=ip1;d22<=d21;a12<=a11;a22<=a21;
 end
 if(valid[3])begin
   feedback13<=filtered2*a12;feedback23<=filtered2*a22;
   weighted3<=filtered2*gain2;ip3<=ip2;d23<=d22;
 end
 if(valid[4])begin
   d1wide4<=($signed({{29{d23[23]}},d23})<<<26)-$signed(feedback13);
   d2wide4<=-$signed(ip3)-$signed(feedback23);
   weighted4<=weighted3>>>20;
 end
 if(valid[5])begin
   nd15<=sat24(rounded_d1);nd25<=sat24(rounded_d2);
   release5<=weighted4*$signed({1'b0,release_words[v5]});
 end
 if(valid[6])begin states[tag[6]]<={nd25,nd15};weighted6<=release5>>>24;end
 if(valid[7])velocity7<=weighted6*$signed({1'b0,velocity_words[v7]});
 if(valid[8])contribution8<=velocity7>>>20;
 if(valid[9])contribution9<=contribution8;
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin issuing<=0;address<=0;valid<=0;done<=0;overflow<=0;sum<=0;accum<=0;
   for(j=0;j<11;j=j+1)tag[j]<=0;
 end else begin
   done<=0;valid<={valid[9:0],issuing};tag[0]<=address;
   for(j=1;j<11;j=j+1)tag[j]<=tag[j-1];
   if(start)begin issuing<=1;address<=0;accum<=0;end
   else if(issuing)begin if(address==63)issuing<=0;else address<=address+1'b1;end
   if(valid[2] && (rounded_f>8388607 || rounded_f< -8388608))overflow<=1;
   if(valid[5] && (rounded_d1>8388607 || rounded_d1< -8388608 || rounded_d2>8388607 || rounded_d2< -8388608))overflow<=1;
   if(valid[10])begin accum<=accum+contribution9;
     if(tag[10]==63)begin sum<=accum+contribution9;done<=1;end
   end
 end
end
endmodule
