// Lossless 8 x signed21 PCM per DDR BL8, with embedded generation/index/CRC.
// All elastic storage consists of small explicit registers, no BSRAM.
// Native requests are serialized; write completion always includes readback.
module loop_store #(parameter DEADLINE=4500)(
 input clk,reset_n,clear_fault,memory_ready,bridge_fault,
 input play_enable,input [1:0] play_bank,input [31:0] play_generation,
 input standby_enable,input [1:0] standby_bank,input [31:0] standby_generation,
 input [21:0] position,length,known_blocks,
 output reg signed [20:0] play_sample,output reg play_available,
 input write_valid,input [1:0] write_bank,input [31:0] write_generation,
 input [21:0] write_position,input signed [20:0] write_sample,input write_last,
 output reg [31:0] verified_generation,output reg [21:0] verified_blocks,
 output reg [7:0] fault,output reg [31:0] max_service_cycles,output idle,
 output reg request,write,output reg [28:0] address,output reg [255:0] wdata,
 input ready,response,error,input [255:0] rdata);
 reg [167:0] pack;
 reg pending;reg [223:0] pending_payload;reg [1:0] pending_bank;
 reg [255:0] active_data;reg [1:0] active_bank;reg [31:0] active_generation;
 reg [21:0] active_index;reg [2:0] operation;reg [4:0] state;
 reg [$clog2(DEADLINE)-1:0] elapsed;
 reg readback_match;
 assign idle=state==0 && !pending && !write_valid;
 // Current and speculative next burst, plus verified candidate head at wrap.
 reg [167:0] cache0,cache1,head,standby;
 reg standby_valid;reg [1:0] standby_b;reg [31:0] standby_g;
 reg [21:0] index0,index1;reg [31:0] gen0,gen1,head_gen;
 reg [1:0] bank0,bank1,head_bank;
 reg valid0,valid1,head_valid,victim;
 wire [21:0] wanted=position>>3;
 reg [21:0] last_index;
 always @(posedge clk)last_index<=(length-1'b1)>>3;
 wire [21:0] ahead=wanted==last_index?22'd0:wanted+1'b1;
 wire hit0=valid0 && bank0==play_bank && gen0==play_generation && index0==wanted;
 wire hit1=valid1 && bank1==play_bank && gen1==play_generation && index1==wanted;
 wire hith=head_valid && head_bank==play_bank && head_gen==play_generation && wanted==0;
 wire hits=standby_valid && standby_b==play_bank && standby_g==play_generation && wanted==0;
 wire ahead_hit=(valid0 && bank0==play_bank && gen0==play_generation && index0==ahead)||
   (valid1 && bank1==play_bank && gen1==play_generation && index1==ahead)||
   (head_valid && head_bank==play_bank && head_gen==play_generation && ahead==0);
 wire [167:0] selected=hit0?cache0:hit1?cache1:hith?head:standby;
 // Audio consumption is hundreds of clocks after the frame boundary. Break
 // tag compare -> cache mux -> lane mux -> gain arithmetic into timed stages.
 always @(posedge clk or negedge reset_n)
 if(!reset_n)begin play_sample<=0;play_available<=0;end
 else begin
  play_sample<=$signed(selected[position[2:0]*21+:21]);
  play_available<=play_enable && !fault && (hit0 || hit1 || hith || hits);
 end
 reg crc_start;wire crc_done,crc_busy;wire [31:0] crc_result;
 loop_crc32 crc(.clk(clk),.reset_n(reset_n),.start(crc_start),.data(active_data[223:0]),.busy(crc_busy),.done(crc_done),.result(crc_result));
 function [28:0] location;input [1:0] b;input [21:0] ix;
  begin case(b)0:location=29'h0040000;1:location=29'h02c0000;default:location=29'h0540000;endcase
   location=location+(ix<<3);end
 endfunction
 wire [167:0] packed_sample=(write_position[2:0]==0?168'd0:pack) |
    ({{147{1'b0}},write_sample} << (write_position[2:0]*21));
 reg [2:0] selection;
 reg [1:0] selected_bank;reg [31:0] selected_generation;reg [21:0] selected_index;
 // Retimed eligibility predicates carry the same bank/generation/index
 // snapshot. No delayed predicate can be combined with a newer tail address.
 // Capture the complete request identity before tag comparison/prefetch.
 // Playback state/position muxes terminate here, rather than in ahead_r.
 reg pref_enable,pref_standby_enable,pref_memory_ready;
 reg [1:0] pref_bank,pref_standby_bank;
 reg [31:0] pref_generation,pref_standby_generation;
 reg [21:0] pref_wanted,pref_ahead,pref_known;
 always @(posedge clk or negedge reset_n)
 if(!reset_n)begin
  pref_enable<=0;pref_standby_enable<=0;pref_memory_ready<=0;
  pref_bank<=0;pref_standby_bank<=0;pref_generation<=0;pref_standby_generation<=0;
  pref_wanted<=0;pref_ahead<=0;pref_known<=0;
 end else begin
  pref_enable<=play_enable;pref_standby_enable<=standby_enable;pref_memory_ready<=memory_ready;
  pref_bank<=play_bank;pref_standby_bank<=standby_bank;
  pref_generation<=play_generation;pref_standby_generation<=standby_generation;
  pref_wanted<=wanted;pref_ahead<=ahead;pref_known<=known_blocks;
 end
 wire pref_hit=(valid0 && bank0==pref_bank && gen0==pref_generation && index0==pref_wanted)||
   (valid1 && bank1==pref_bank && gen1==pref_generation && index1==pref_wanted)||
   (head_valid && head_bank==pref_bank && head_gen==pref_generation && pref_wanted==0)||
   (standby_valid && standby_b==pref_bank && standby_g==pref_generation && pref_wanted==0);
 wire pref_ahead_hit=(valid0 && bank0==pref_bank && gen0==pref_generation && index0==pref_ahead)||
   (valid1 && bank1==pref_bank && gen1==pref_generation && index1==pref_ahead)||
   (head_valid && head_bank==pref_bank && head_gen==pref_generation && pref_ahead==0);
 reg demand_r,ahead_r,standby_r;
 reg [1:0] play_bank_r,standby_bank_r;
 reg [31:0] play_gen_r,standby_gen_r;
 reg [21:0] wanted_r,ahead_index_r;
 always @(posedge clk or negedge reset_n)
 if(!reset_n)begin
  demand_r<=0;ahead_r<=0;standby_r<=0;play_bank_r<=0;standby_bank_r<=0;
  play_gen_r<=0;standby_gen_r<=0;wanted_r<=0;ahead_index_r<=0;
  selection<=0;selected_bank<=0;selected_generation<=0;selected_index<=0;
 end else begin
  demand_r<=pref_enable && pref_memory_ready && pref_wanted<pref_known && !pref_hit;
  ahead_r<=pref_enable && pref_memory_ready && pref_ahead<pref_known && !pref_ahead_hit;
  standby_r<=pref_standby_enable && pref_memory_ready && !(standby_valid && standby_b==pref_standby_bank && standby_g==pref_standby_generation);
  play_bank_r<=pref_bank;play_gen_r<=pref_generation;wanted_r<=pref_wanted;ahead_index_r<=pref_ahead;
  standby_bank_r<=pref_standby_bank;standby_gen_r<=pref_standby_generation;
  selection<=0;
  if(demand_r)begin selection<=1;selected_bank<=play_bank_r;selected_generation<=play_gen_r;selected_index<=wanted_r;end
  else if(pending && memory_ready)begin selection<=2;end
  else if(ahead_r)begin selection<=3;selected_bank<=play_bank_r;selected_generation<=play_gen_r;selected_index<=ahead_index_r;end
  else if(standby_r)begin selection<=4;selected_bank<=standby_bank_r;selected_generation<=standby_gen_r;selected_index<=0;end
 end
 always @(posedge clk or negedge reset_n)
 if(!reset_n)begin
  pack<=0;pending<=0;pending_payload<=0;pending_bank<=0;active_data<=0;active_bank<=0;active_generation<=0;active_index<=0;operation<=0;state<=0;elapsed<=0;readback_match<=0;
  cache0<=0;cache1<=0;head<=0;index0<=0;index1<=0;gen0<=0;gen1<=0;head_gen<=0;bank0<=0;bank1<=0;head_bank<=0;valid0<=0;valid1<=0;head_valid<=0;victim<=0;
  verified_generation<=0;verified_blocks<=0;fault<=0;max_service_cycles<=0;request<=0;write<=0;address<=0;wdata<=0;crc_start<=0;
  standby<=0;standby_valid<=0;standby_b<=0;standby_g<=0;
 end else begin
  request<=0;crc_start<=0;
  if(state!=0 && !fault)begin elapsed<=elapsed+1'b1;if(elapsed>max_service_cycles)max_service_cycles<=elapsed;end
  if(write_valid && !fault)begin
   pack<=packed_sample;
   if(write_position[2:0]==7 || write_last)begin
    if(pending)fault<=8'd4;
    else begin pending<=1;pending_bank<=write_bank;pending_payload<={2'b01,write_generation,(write_position>>3),packed_sample};end
   end
  end
  if(clear_fault && !bridge_fault && memory_ready && state==0)begin fault<=0;pending<=0;valid0<=0;valid1<=0;head_valid<=0;standby_valid<=0;pack<=0;end
  if(!fault)case(state)
  0:begin
   elapsed<=0;
   // Demand read wins; bounded prefetch after a queued write. No starvation:
   // one write/readback is far shorter than eight sample periods.
   if(selection==1 && memory_ready)begin
    active_bank<=selected_bank;active_generation<=selected_generation;active_index<=selected_index;operation<=0;state<=1;
   end else if(selection==2 && pending && memory_ready)begin
    pending<=0;active_data<={32'd0,pending_payload};active_bank<=pending_bank;
    active_generation<=pending_payload[221:190];active_index<=pending_payload[189:168];operation<=1;state<=4;
   end else if(selection==3 && memory_ready)begin
    active_bank<=selected_bank;active_generation<=selected_generation;active_index<=selected_index;operation<=0;state<=1;
   end else if(selection==4 && memory_ready)begin
    active_bank<=selected_bank;active_generation<=selected_generation;active_index<=selected_index;operation<=2;state<=1;
   end
  end
  1:if(ready)begin address<=location(active_bank,active_index);write<=0;request<=1;state<=2;end
  2:if(response)begin
    if(error)begin fault<=1;state<=0;end
    else if(operation==1)begin
     // A complete 256-bit readback compare is its own timing stage.
     readback_match<=rdata==active_data;state<=8;
    end else begin active_data<=rdata;state<=4;end
  end
  8:begin
   if(!readback_match)fault<=2;
   else begin
    if(verified_generation!=active_generation)begin verified_generation<=active_generation;verified_blocks<=1;end
    else verified_blocks<=active_index+1'b1;
    if(active_index==0)begin head<=active_data[167:0];head_gen<=active_generation;head_bank<=active_bank;head_valid<=1;end
   end
   state<=0;
  end
  4:begin crc_start<=1;state<=5;end
  5:if(crc_done)begin
   if(operation==1)begin active_data[255:224]<=crc_result;state<=6;end
   else if(active_data[255:224]!=crc_result || active_data[223:222]!=1 ||
      active_data[221:190]!=active_generation || active_data[189:168]!=active_index)begin fault<=3;state<=0;end
   else begin
    // Evict neither the demanded block nor the head; head has its own slot.
    if(operation==2)begin standby<=active_data[167:0];standby_valid<=1;standby_b<=active_bank;standby_g<=active_generation;end
    else if(!valid0 || !(hit0 || (valid1 && !hit1)))begin cache0<=active_data[167:0];gen0<=active_generation;bank0<=active_bank;index0<=active_index;valid0<=1;end
    else begin cache1<=active_data[167:0];gen1<=active_generation;bank1<=active_bank;index1<=active_index;valid1<=1;end
    victim<=!victim;state<=0;
   end
  end
  6:if(ready)begin address<=location(active_bank,active_index);wdata<=active_data;write<=1;request<=1;state<=7;end
  7:if(response)begin if(error)begin fault<=1;state<=0;end else state<=1;end
  default:state<=0;
  endcase
  if(fault)begin state<=0;pending<=0;request<=0;end
  if(bridge_fault || ((play_enable || pending || state!=0) && !memory_ready))fault<=5;
  if(state!=0 && elapsed==DEADLINE-1)fault<=6;
 end
endmodule
