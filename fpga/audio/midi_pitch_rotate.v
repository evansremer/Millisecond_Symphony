// Fixed-pitch compatibility pipeline; MIDI kind 3 is reserved and ignored.
// 26 stages retain frame timing. Shallow delay uses registers.
module midi_pitch_rotate #(parameter PAYLOAD_BITS=1)(
 input clk,rst_n,in_valid,input signed [27:0] a,b,
 input signed [32:0] angle,input [17:0] ratio,
 input [PAYLOAD_BITS-1:0] payload,
 output out_valid,output signed [27:0] out_a,out_b,
 output [PAYLOAD_BITS-1:0] out_payload
);
 (* syn_srlstyle="registers", syn_ramstyle="registers", ram_style="registers" *) reg [55:0] original[0:25];
 (* syn_srlstyle="registers", syn_ramstyle="registers", ram_style="registers" *) reg [PAYLOAD_BITS-1:0] data[0:25];
 reg [25:0] valid;integer k;
 always @(posedge clk)begin
  original[0]<={a,b};data[0]<=payload;
  for(k=1;k<26;k=k+1)begin original[k]<=original[k-1];data[k]<=data[k-1];end
 end
 always @(posedge clk or negedge rst_n)
  if(!rst_n)valid<=0;else valid<={valid[24:0],in_valid};
 assign out_a=original[25][55:28];assign out_b=original[25][27:0];
 assign out_payload=data[25];assign out_valid=valid[25];
endmodule
