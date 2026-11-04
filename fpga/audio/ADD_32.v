`timescale 1ns/1ps
`default_nettype none
// Eleven lanes, one shared adder. Original lane calibration is retained;
// optional independent pre-gain uses widened shifts before the final clamp.
// 0/1 piano, 2..4 drum, 5/6 ADC, 7..9 horn, 10 ordinary LUT synth.
module mixer_sum_11 #(
 parameter integer KEYBOARD_PRE_SHIFT=0,
 parameter integer DRUM_PRE_SHIFT=0
)(
 input wire clk,rst_n,start,
 input wire [208:0] sample_bus,
 output reg signed [20:0] mixed_sample,
 output reg mixed_valid,busy,overrun,clipped
);
reg [3:0] lane_index;
localparam integer PRE_SHIFT_MAX=KEYBOARD_PRE_SHIFT>DRUM_PRE_SHIFT?KEYBOARD_PRE_SHIFT:DRUM_PRE_SHIFT;
localparam integer ACC_BITS=24+PRE_SHIFT_MAX;
reg signed [ACC_BITS-1:0] accumulator;
wire signed [18:0] lane_sample=$signed(sample_bus[lane_index*19 +:19]);
wire signed [ACC_BITS-1:0] extended={{(ACC_BITS-19){lane_sample[18]}},lane_sample};
wire drum_lane=lane_index>=2 && lane_index<=4;
wire keyboard_lane=lane_index<=1 || lane_index>=7;
wire signed [ACC_BITS-1:0] scaled=drum_lane ? (extended<<<(3+DRUM_PRE_SHIFT)) :
 keyboard_lane ? (extended<<<KEYBOARD_PRE_SHIFT) : extended;
wire signed [ACC_BITS-1:0] next_sum=accumulator+scaled;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin lane_index<=0;accumulator<=0;mixed_sample<=0;mixed_valid<=0;busy<=0;overrun<=0;clipped<=0;end
 else begin
  mixed_valid<=0;overrun<=start && busy;
  if(!busy)begin
   if(start)begin lane_index<=0;accumulator<=0;busy<=1;end
  end else if(lane_index==10)begin
   if(next_sum>24'sd1048575)begin mixed_sample<=21'sh0fffff;clipped<=1;end
   else if(next_sum < -24'sd1048576)begin mixed_sample<=21'sh100000;clipped<=1;end
   else mixed_sample<=next_sum[20:0];
   mixed_valid<=1;busy<=0;
  end else begin accumulator<=next_sum;lane_index<=lane_index+1'b1;end
 end
end
endmodule
`default_nettype wire
