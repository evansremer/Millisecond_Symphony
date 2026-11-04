// One white source, 4 independent band filters per active voice; no hit histories.
// The AD envelope is v*(slow-fast), two decaying states. Retrigger resets only AD.
// Shallow state/parameter banks use distributed RAM, avoiding wide shallow BRAM waste.
module piano_noise_engine # (parameter PARAM_FILE="piano_noise.mem")(
input wire clk,rst_n,start,
input wire [15:0] active,strike,fresh,
input wire [79:0] key_bus,velocity_bus,
input wire signed [23:0] white,
output reg busy,done,overflow,
output reg signed [39:0] sum,
output reg [15:0] quiet
);
`include "piano_math.vh"
(* rom_style="distributed" *) reg [163:0] params[0:127];
(* ram_style="distributed" *) reg [95:0] states[0:63];
reg [163:0] pq;
reg [95:0] sq;
reg issuing;
reg [5:0] address;
reg [7:0] valid;
reg [5:0] tag[0:7];
wire [6:0] param_address={key_bus[address[5:2]*5 +:5],address[1:0]};
wire [3:0] v0=tag[0][5:2],v6=tag[6][5:2];
wire [23:0] velocity_level=velocity_bus[v0*5 +:5]*24'd67650;
reg signed [23:0] d10,d20;
reg [23:0] slow0,fast0;
reg signed [27:0] alpha_s0,alpha_f0,a10,a20,a11,a21,a12,a22;
reg signed [23:0] gain0,gain1,gain2,gain3,gain4;
(* use_dsp="yes" *) reg signed [51:0] input_product0,slow_product1,fast_product1;
reg signed [51:0] input_product1,input_product2,input_product3;
reg signed [23:0] d21,d22,d23;
reg signed [52:0] fwide1;
reg signed [24:0] envelope1;
reg signed [23:0] filtered2,envelope2;
reg [23:0] slow2,fast2,slow3,fast3,slow4,fast4,slow5,fast5;
(* use_dsp="yes" *) reg signed [51:0] feedback_a3,feedback_b3;
(* use_dsp="yes" *) reg signed [47:0] envelope_product3,weighted_product5;
reg signed [52:0] d1wide4,d2wide4;
reg signed [23:0] normalized4,next_d15,next_d25;
reg signed [39:0] contribution6,accumulator;
wire signed [52:0] f_rounded=p_round(fwide1,26);
wire signed [52:0] d1_rounded=p_round(d1wide4,26);
wire signed [52:0] d2_rounded=p_round(d2wide4,26);
integer t;
initial $readmemh(PARAM_FILE,params);
always @(posedge clk)begin
    if(issuing)begin pq<=params[param_address];sq<=states[address];end
    if(valid[0])begin
        input_product0<=$signed(pq[27:0])*white;
        a10<=pq[55:28];a20<=pq[83:56];alpha_s0<=pq[111:84];alpha_f0<=pq[139:112];gain0<=pq[163:140];
        d10<=(active[v0] && !fresh[v0])?$signed(sq[23:0]):24'sd0;
        d20<=(active[v0] && !fresh[v0])?$signed(sq[47:24]):24'sd0;
        slow0<=!active[v0]?24'd0:(strike[v0]?velocity_level:(fresh[v0]?24'd0:sq[71:48]));
        fast0<=!active[v0]?24'd0:(strike[v0]?velocity_level:(fresh[v0]?24'd0:sq[95:72]));
    end
    if(valid[1])begin
        fwide1<=$signed(input_product0)+($signed({{29{d10[23]}},d10})<<<26);
        slow_product1<=$signed(slow0)*alpha_s0;fast_product1<=$signed(fast0)*alpha_f0;
        envelope1<=$signed({1'b0,slow0})-$signed({1'b0,fast0});
        input_product1<=input_product0;d21<=d20;a11<=a10;a21<=a20;gain1<=gain0;
    end
    if(valid[2])begin
        filtered2<=p_sat24(f_rounded);envelope2<=p_sat24(envelope1);
        slow2<=slow_product1>>>26;fast2<=fast_product1>>>26; // Floor: envelope cannot refill a limit cycle.
        input_product2<=input_product1;d22<=d21;a12<=a11;a22<=a21;gain2<=gain1;
    end
    if(valid[3])begin
        feedback_a3<=filtered2*a12;feedback_b3<=filtered2*a22;
        envelope_product3<=filtered2*envelope2;
        input_product3<=input_product2;d23<=d22;slow3<=slow2;fast3<=fast2;gain3<=gain2;
    end
    if(valid[4])begin
        d1wide4<=($signed({{29{d23[23]}},d23})<<<26)-$signed(feedback_a3);
        d2wide4<=-$signed({input_product3[51],input_product3})-$signed(feedback_b3);
        normalized4<=p_sat24(p_round(envelope_product3,21));
        slow4<=slow3;fast4<=fast3;gain4<=gain3;
    end
    if(valid[5])begin
        next_d15<=p_sat24(d1_rounded);next_d25<=p_sat24(d2_rounded);
        weighted_product5<=normalized4*gain4;slow5<=slow4;fast5<=fast4;
    end
    if(valid[6])begin
        states[tag[6]]<=active[v6]?{fast5,slow5,next_d25,next_d15}:96'd0;
        contribution6<=p_round(weighted_product5,21);
    end
end
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        busy<=0;done<=0;overflow<=0;sum<=0;quiet<=16'hffff;issuing<=0;address<=0;valid<=0;accumulator<=0;
        for(t=0;t<8;t=t+1)tag[t]<=0;
    end else begin
        done<=0;valid<={valid[6:0],issuing};tag[0]<=address;
        for(t=1;t<8;t=t+1)tag[t]<=tag[t-1];
        if(start)begin
            accumulator<=0;quiet<=16'hffff;address<=0;
            if(active==0)begin busy<=0;sum<=0;done<=1;end
            else begin issuing<=1;busy<=1;end
        end else if(issuing)begin if(address==63)issuing<=0;else address<=address+1'b1;end
        if(valid[2] && p_clip24(f_rounded))overflow<=1;
        if(valid[4] && p_clip24(p_round(envelope_product3,21)))overflow<=1;
        if(valid[5] && (p_clip24(d1_rounded) || p_clip24(d2_rounded)))overflow<=1;
        if(valid[6] && (slow5!=0 || fast5!=0))quiet[v6]<=0;
        if(valid[7])begin
            accumulator<=accumulator+contribution6;
            if(tag[7]==63)begin sum<=accumulator+contribution6;busy<=0;done<=1;end
        end
    end
end
endmodule
