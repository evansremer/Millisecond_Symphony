`timescale 1ns/1ps
`default_nettype none
// One mono track. REC and PLAY are mutually exclusive. No overdub.
// Commands are applied at in_valid boundaries; control frames pass live audio only.
module audio_loop #(
 parameter integer MAX_SAMPLES=2880000,
 parameter integer TIMEOUT_CYCLES=1048576
)(
 input wire clk,rst_n,in_valid,button_pulse,memory_ready,
 input wire signed [20:0] in_sample,
 output reg out_valid,
 output reg signed [20:0] out_sample,
 output reg [3:0] state,
 output reg [21:0] loop_length,
 output reg fault,clipped,command_rejected,
 output reg req_valid,req_write,
 input wire req_ready,rsp_valid,rsp_error,
 output reg [21:0] req_addr,
 output reg [31:0] req_data,
 input wire [31:0] rsp_data
);
localparam EMPTY=0,REC=1,FLUSH=2,READY=3,PREFILL=4,PLAY=5,DRAIN=6,STOPPED=7,ERROR=8;
reg button_pending,transaction;
reg [20:0] watchdog;
reg [21:0] write_index,fetch_index;
// Small distributed queues, never a register array for the long recording.
(* ram_style="distributed" *) reg signed [20:0] wmem[0:63];
(* ram_style="distributed" *) reg signed [20:0] rmem[0:31];
reg [5:0] wp,wr;
reg [4:0] rp,rr;
reg [6:0] wc;
reg [5:0] rc;
wire action=in_valid && (button_pending || button_pulse);
wire recording_push=in_valid && state==REC && !action && wc<64;
wire schedule_write=!transaction && !req_valid && wc!=0 && (state==REC || state==FLUSH) && memory_ready;
wire schedule_read=!transaction && !req_valid && rc<16 && (state==PREFILL || state==PLAY) && memory_ready && !action;
wire read_return=rsp_valid && transaction && !req_write && !rsp_error && (state==PREFILL || state==PLAY);
wire playback_pop=in_valid && state==PLAY && !action && rc!=0;
wire signed [21:0] mixed=$signed({in_sample[20],in_sample})+$signed({rmem[rr][20],rmem[rr]});
always @(posedge clk)begin
 if(recording_push)wmem[wp]<=in_sample;
 if(read_return)rmem[rp]<=rsp_data[20:0];
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=EMPTY;loop_length<=0;write_index<=0;fetch_index<=0;
  fault<=0;clipped<=0;command_rejected<=0;out_valid<=0;out_sample<=0;
  wp<=0;wr<=0;wc<=0;rp<=0;rr<=0;rc<=0;
  button_pending<=0;transaction<=0;watchdog<=0;
  req_valid<=0;req_write<=0;req_addr<=0;req_data<=0;
 end else begin
  out_valid<=in_valid;clipped<=0;command_rejected<=0;
  if(button_pulse)button_pending<=1;
  if(action)button_pending<=0;
  // Fixed one-clock audio latency, independent of memory readiness/latency.
  if(in_valid)begin
   out_sample<=in_sample;
   if(playback_pop && !fault)begin
    if(mixed>22'sd1048575)begin out_sample<=21'sh0fffff;clipped<=1;end
    else if(mixed < -22'sd1048576)begin out_sample<=21'sh100000;clipped<=1;end
    else out_sample<=mixed[20:0];
   end
  end
  if(recording_push)begin
   wp<=wp+1'b1;loop_length<=loop_length+1'b1;
   if(loop_length==MAX_SAMPLES-1)state<=FLUSH;
  end
  if(schedule_write)begin
   req_valid<=1;req_write<=1;req_addr<=write_index;
   req_data<={{11{wmem[wr][20]}},wmem[wr]};
   wr<=wr+1'b1;write_index<=write_index+1'b1;
  end
  case({recording_push,schedule_write})
   2'b10:wc<=wc+1'b1;2'b01:wc<=wc-1'b1;default:begin end
  endcase
  if(schedule_read)begin
   req_valid<=1;req_write<=0;req_addr<=fetch_index;req_data<=0;
   if(fetch_index==loop_length-1'b1)fetch_index<=0;
   else fetch_index<=fetch_index+1'b1;
  end
  if(req_valid && req_ready)begin req_valid<=0;transaction<=1;end
  if(rsp_valid && transaction)transaction<=0;
  if(read_return)rp<=rp+1'b1;
  if(playback_pop)rr<=rr+1'b1;
  case({read_return,playback_pop})
   2'b10:rc<=rc+1'b1;2'b01:rc<=rc-1'b1;default:begin end
  endcase
  if(state==FLUSH && wc==0 && !req_valid && !transaction)state<=READY;
  if(state==PREFILL && rc>=8)state<=PLAY;
  if(state==DRAIN && !req_valid && !transaction)begin
   state<=STOPPED;rp<=0;rr<=0;rc<=0;fetch_index<=0;
  end
  if(action)begin
   case(state)
    EMPTY,STOPPED:begin
     if(memory_ready && !fault)begin
      state<=REC;loop_length<=0;write_index<=0;fetch_index<=0;
      wp<=0;wr<=0;wc<=0;rp<=0;rr<=0;rc<=0;
     end else command_rejected<=1;
    end
    REC:state<=FLUSH;
    READY:begin
     if(loop_length!=0 && memory_ready)begin state<=PREFILL;fetch_index<=0;rp<=0;rr<=0;rc<=0;end
     else if(loop_length==0)state<=STOPPED;
     else command_rejected<=1;
    end
    PLAY,PREFILL:state<=DRAIN;
    default:command_rejected<=1;
   endcase
  end
  if(req_valid || transaction)watchdog<=watchdog+1'b1;else watchdog<=0;
  // Fail open for live audio, fail closed for the recording. Reset required.
  if((in_valid && state==REC && !action && wc==64) ||
     (in_valid && state==PLAY && !action && rc==0) ||
     (rsp_valid && transaction && rsp_error) ||
     ((req_valid || transaction) && watchdog==TIMEOUT_CYCLES-1) ||
     (!memory_ready && (state==REC || state==PLAY || state==PREFILL)))begin
   fault<=1;state<=ERROR;loop_length<=0;
  end
 end
end
endmodule
`default_nettype wire
