// One audio track. All transport actions are sample-clocked. MIDI never enters
// this module; only already synthesized live PCM is recorded.
module loop_transport #(parameter NOMINAL_FS=48000)(
 input clk,reset_n,sample_ce,in_valid,input signed [20:0] live,
 input global_stop,test_active,memory_ready,bridge_fault,
 input command_valid,input [127:0] command,
 output reg [15:0] executed_seq,output reg [7:0] rejected,
 output reg out_valid,output reg signed [20:0] out_sample,
 output signed [20:0] click_sample,output active,
 output [511:0] status,
 output request,write,output [28:0] address,output [255:0] wdata,
 input ready,response,error,input [255:0] rdata);
 localparam EMPTY=0,ARM=1,COUNT=2,REC=3,PLAY=4,STOPPED=5,FAULT=6;
 reg [3:0] state;
 reg [7:0] bpm;reg [3:0] bars;reg [5:0] beats;
 reg [21:0] n,phase,position;reg [5:0] beat;
 reg [63:0] samples;
 reg frame_beat,frame_bar;reg [5:0] frame_beat_number;
 reg [2:0] count_beats;
 reg [1:0] active_bank,undo_bank,work_bank;
 reg [31:0] active_gen,undo_gen,work_gen,next_gen;
 reg valid_loop,undo_valid,overdub,od_pending,stop_pending,play_pending,undo_pending,clear_pending,committing,was_od;
 reg [16:0] gain,target_gain,click_gain,target_click_gain;
 // Q15 unity is exactly 32768. Only the incoming layer is attenuated.
 reg [15:0] od_gain,target_od_gain;
 reg click_on,clear_fault;reg [31:0] clips,underruns,completed,od_count;
 reg [7:0] local_fault;
 reg [31:0] click_phase,click_step;reg [15:0] envelope;
 wire beat_now=({1'b0,phase}+beats)>={1'b0,n};
 wire bar_now=beat_now && beat[1:0]==3;
 wire playing=state==PLAY;
 wire [1:0] playback_bank=committing?work_bank:active_bank;
 wire [31:0] playback_gen=committing?work_gen:active_gen;
 wire signed [20:0] playback_sample;wire available;
 reg write_valid,write_last;reg signed [20:0] write_sample;
 reg [21:0] write_position;
 wire [31:0] verified_generation;wire [21:0] verified_blocks;
 wire [7:0] storage_fault;wire [31:0] max_service;
 wire store_idle;
 reg [21:0] total_blocks;
 always @(posedge clk)total_blocks<=(n+22'd7)>>3;
 reg [1:0] saved_write_bank;reg [31:0] saved_write_gen;
 wire preload=state==STOPPED && play_pending;
 loop_store store(.clk(clk),.reset_n(reset_n),.clear_fault(clear_fault),.memory_ready(memory_ready),.bridge_fault(bridge_fault),
  .play_enable(playing||preload),.play_bank(playback_bank),.play_generation(playback_gen),
  .standby_enable(undo_pending),.standby_bank(undo_bank),.standby_generation(undo_gen),
  .position(preload?22'd0:position),.length(n),
  .known_blocks(committing?(verified_generation==work_gen?verified_blocks:22'd0):total_blocks),
  .play_sample(playback_sample),.play_available(available),
  .write_valid(write_valid),.write_bank(saved_write_bank),.write_generation(saved_write_gen),.write_position(write_position),.write_sample(write_sample),.write_last(write_last),
  .verified_generation(verified_generation),.verified_blocks(verified_blocks),.fault(storage_fault),.max_service_cycles(max_service),.idle(store_idle),
  .request(request),.write(write),.address(address),.wdata(wdata),.ready(ready),.response(response),.error(error),.rdata(rdata));
 // Candidate head comes directly from verified writeback. Speculative reads
 // are restricted to its verified prefix; never read unrecorded tail memory.
 wire complete_candidate=verified_generation==work_gen && verified_blocks==total_blocks;
 assign active=state==ARM || state==COUNT || state==REC || state==PLAY || play_pending || committing;
 function signed [20:0] sat21;input signed [42:0] v;
  begin if(v>1048575)sat21=21'sh0fffff;else if(v< -1048576)sat21=21'sh100000;else sat21=v[20:0];end
 endfunction
 wire [21:0] remaining=n-1'b1-position;
 wire [6:0] edge_gain=position<64?position[6:0]:remaining<64?remaining[6:0]:7'd64;
 reg signed [38:0] product;reg signed [45:0] tapered;
 reg signed [42:0] sum;
 reg signed [42:0] od_sum;
 reg signed [37:0] od_product;
 reg signed [20:0] od_old;
 reg od_pipe_valid,od_last;
 reg [21:0] od_position;reg [1:0] od_bank;reg [31:0] od_generation;
 reg [1:0] clip_events;
 reg signed [38:0] preview_product;
 reg signed [28:0] preview_window;
 reg signed [20:0] preview;
 reg [21:0] preview_pos0,preview_pos1,preview_pos2;
 reg [31:0] preview_gen0,preview_gen1,preview_gen2;
 reg [1:0] preview_bank0,preview_bank1,preview_bank2;
 reg [2:0] preview_valid;
 reg [6:0] preview_edge;
 reg [21:0] sample_pos;reg [31:0] sample_gen;reg [1:0] sample_bank;
 wire preview_ready=available && preview_valid[2] && preview_pos2==position && preview_gen2==playback_gen && preview_bank2==playback_bank;
 // Precompute the current sample throughout its 1024-clock frame. Tags make
 // late cache fills fail closed, rather than consuming a previous lane/bank.
 always @(posedge clk or negedge reset_n)
 if(!reset_n)begin
  preview_product<=0;preview_window<=0;preview<=0;preview_valid<=0;preview_edge<=0;sample_pos<=0;sample_gen<=0;sample_bank<=0;
  preview_pos0<=0;preview_pos1<=0;preview_pos2<=0;
  preview_gen0<=0;preview_gen1<=0;preview_gen2<=0;
  preview_bank0<=0;preview_bank1<=0;preview_bank2<=0;
 end else begin
  preview_product<=$signed(playback_sample)*$signed({1'b0,gain});
  preview_edge<=edge_gain;
  preview_window<=$signed(preview_product[36:16])*$signed({1'b0,preview_edge});
  preview<=preview_window>>>6;
  preview_pos0<=position;preview_pos1<=preview_pos0;preview_pos2<=preview_pos1;
  preview_gen0<=playback_gen;preview_gen1<=preview_gen0;preview_gen2<=preview_gen1;
  preview_bank0<=playback_bank;preview_bank1<=preview_bank0;preview_bank2<=preview_bank1;
  sample_pos<=position;sample_gen<=playback_gen;sample_bank<=playback_bank;
  preview_valid<={preview_valid[1:0],available && sample_pos==position && sample_gen==playback_gen && sample_bank==playback_bank};
 end
 reg signed [20:0] last_verified_audio;reg [16:0] release_gain;
 wire signed [38:0] release_product=$signed(last_verified_audio)*$signed({1'b0,release_gain});
 wire signed [20:0] click_raw=click_on && !global_stop ? (click_phase[31]?-$signed({1'b0,envelope,4'd0}):$signed({1'b0,envelope,4'd0})) : 21'sd0;
 wire signed [38:0] click_product=$signed(click_raw)*$signed({1'b0,click_gain});
 reg signed [20:0] click_registered;
 always @(posedge clk or negedge reset_n)
 if(!reset_n)click_registered<=0;else click_registered<=click_product>>>16;
 assign click_sample=global_stop?21'sd0:click_registered;
 // Header is FPGA-authoritative. CPU never guesses whether an action started.
 wire [5:0] remaining_beats=state==ARM ? (6'd4-{4'd0,beat[1:0]})+4 : state==COUNT ? {3'd0,count_beats} : play_pending ? (6'd4-{4'd0,beat[1:0]}) : beats-beat;
 assign status[31:0]={8'd0,storage_fault,local_fault,store_idle,bridge_fault,memory_ready,valid_loop,state};
 assign status[63:32]={od_gain,bars,4'd0,bpm};
 assign status[95:64]={10'd0,n};
 assign status[127:96]={10'd0,position};
 assign status[159:128]={8'd0,remaining_beats,beat,3'd0,click_on,committing,clear_pending,undo_pending,play_pending,stop_pending,overdub,od_pending,undo_valid};
 assign status[191:160]=samples[31:0];assign status[223:192]=samples[63:32];
 assign status[255:224]={8'd0,rejected,executed_seq};
 assign status[287:256]={15'd0,gain};assign status[319:288]={15'd0,click_gain};
 assign status[351:320]=clips;assign status[383:352]=underruns;
 assign status[415:384]=max_service;assign status[447:416]=completed;
 assign status[479:448]=od_count;assign status[511:480]=active_gen;
 reg [127:0] cfg_pending;reg cfg_wait,recover_pending;
 reg frame_arm,frame_count,frame_replay,frame_od,frame_stop,frame_undo,frame_clear;
 wire [7:0] op=command[7:0];wire [15:0] seq=command[127:112];
 wire cancel_od=command_valid && seq!=executed_seq && op==4 && playing && overdub && !committing && !stop_pending && !undo_pending && !clear_pending;
 always @(posedge clk or negedge reset_n)
 if(!reset_n)begin
  state<=EMPTY;bpm<=120;bars<=2;beats<=8;n<=NOMINAL_FS*4;phase<=0;position<=0;beat<=0;samples<=0;
  frame_beat<=0;frame_bar<=0;frame_beat_number<=0;count_beats<=0;
  active_bank<=0;undo_bank<=1;work_bank<=2;active_gen<=0;undo_gen<=0;work_gen<=0;next_gen<=1;
  valid_loop<=0;undo_valid<=0;overdub<=0;od_pending<=0;stop_pending<=0;play_pending<=0;undo_pending<=0;clear_pending<=0;committing<=0;was_od<=0;
  gain<=32768;target_gain<=32768;click_gain<=13107;target_click_gain<=13107;click_on<=0;clear_fault<=0;clips<=0;underruns<=0;completed<=0;od_count<=0;local_fault<=0;
  od_gain<=32768;target_od_gain<=32768;od_product<=0;od_old<=0;od_pipe_valid<=0;od_last<=0;od_position<=0;od_bank<=0;od_generation<=0;clip_events=0;
  click_phase<=0;click_step<=0;envelope<=0;write_valid<=0;write_last<=0;write_sample<=0;write_position<=0;saved_write_bank<=0;saved_write_gen<=0;
  out_valid<=0;out_sample<=0;executed_seq<=0;rejected<=0;product<=0;tapered<=0;sum<=0;od_sum<=0;cfg_pending<=0;cfg_wait<=0;recover_pending<=0;last_verified_audio<=0;release_gain<=0;
  frame_arm<=0;frame_count<=0;frame_replay<=0;frame_od<=0;frame_stop<=0;frame_undo<=0;frame_clear<=0;
 end else begin
  write_valid<=0;clear_fault<=0;out_valid<=0;od_pipe_valid<=0;clip_events=0;
  // The multiplier is registered before addition/saturation. Metadata follows
  // the same stage; canceled/failed takes cannot leak a delayed write.
  if(od_pipe_valid && !global_stop && !storage_fault && !bridge_fault && !local_fault && !cancel_od)begin
   od_sum=$signed(od_old)+(($signed(od_product)+38'sd16384)>>>15);
   write_valid<=1;write_sample<=sat21(od_sum);write_position<=od_position;write_last<=od_last;saved_write_bank<=od_bank;saved_write_gen<=od_generation;
   if(od_sum>1048575 || od_sum< -1048576)clip_events[1]=1;
  end
  if(sample_ce)begin
   samples<=samples+1'b1;frame_beat<=beat_now;frame_bar<=bar_now;frame_beat_number<=beat==beats-1?0:beat+1'b1;
   frame_arm<=state==ARM;frame_count<=state==COUNT;frame_replay<=play_pending;frame_od<=od_pending;frame_stop<=stop_pending;frame_undo<=undo_pending;frame_clear<=clear_pending;
   if(beat_now)begin phase<=phase+beats-n;beat<=beat==beats-1?0:beat+1'b1;end else phase<=phase+beats;
   if(gain<target_gain)gain<=target_gain-gain>128?gain+128:target_gain;else if(gain>target_gain)gain<=gain-target_gain>128?gain-128:target_gain;
   if(click_gain<target_click_gain)click_gain<=target_click_gain-click_gain>128?click_gain+128:target_click_gain;
   else if(click_gain>target_click_gain)click_gain<=click_gain-target_click_gain>128?click_gain-128:target_click_gain;
   if(od_gain<target_od_gain)od_gain<=target_od_gain-od_gain>64?od_gain+64:target_od_gain;
   else if(od_gain>target_od_gain)od_gain<=od_gain-target_od_gain>64?od_gain-64:target_od_gain;
   click_phase<=click_phase+click_step;
   if(beat_now && click_on && !global_stop)begin envelope<=beat[1:0]==3?4095:2815;click_phase<=0;click_step<=beat[1:0]==3?32'd107374182:32'd71582788;end
   else envelope<=envelope>18?envelope-18:0;
   if(cfg_wait && bar_now)begin
    n<=cfg_pending[53:32];bpm<=cfg_pending[15:8];bars<=cfg_pending[19:16];beats<={cfg_pending[19:16],2'b0};phase<=0;beat<=0;cfg_wait<=0;
   end
  end
  if(committing && complete_candidate && !global_stop && !storage_fault && !local_fault)begin
   if(was_od)begin undo_bank<=active_bank;undo_gen<=active_gen;undo_valid<=1;work_bank<=undo_bank;od_count<=od_count+1'b1;end
   else begin work_bank<=active_bank;undo_valid<=0;end
   active_bank<=work_bank;active_gen<=work_gen;valid_loop<=1;committing<=0;completed<=completed+1'b1;
  end
  if(in_valid)begin
   out_valid<=1;out_sample<=live;
   if(!playing && release_gain!=0)begin
    sum=$signed(live)+(release_product>>>16);out_sample<=sat21(sum);
    release_gain<=release_gain>128?release_gain-128:0;
   end
   if(state==ARM && frame_arm && frame_bar)begin state<=COUNT;count_beats<=4;end
   if(state==COUNT && frame_count && frame_beat)begin
    if(count_beats==1)begin state<=REC;position<=1;beat<=0;phase<=0;work_gen<=next_gen;next_gen<=next_gen+1'b1;
     write_valid<=1;write_sample<=live;write_position<=0;write_last<=0;saved_write_bank<=work_bank;saved_write_gen<=next_gen;
    end else count_beats<=count_beats-1'b1;
   end
   if(state==REC)begin
    write_valid<=1;write_sample<=live;write_position<=position;write_last<=position==n-1;saved_write_bank<=work_bank;saved_write_gen<=work_gen;
    if(position==n-1)begin position<=0;state<=PLAY;committing<=1;was_od<=0;end else position<=position+1'b1;
   end
   if(state==STOPPED && play_pending && frame_replay && frame_bar)begin state<=PLAY;position<=1;play_pending<=0;beat<=0;phase<=0;
    // First sample uses a preloaded start block (read enable includes pending).
    if(available)begin product=$signed(playback_sample)*$signed({1'b0,gain});out_sample<=live;end
    else begin local_fault<=1;underruns<=underruns+1'b1;state<=FAULT;end
   end
   if(playing)begin
    if(!preview_ready)begin
     local_fault<=1;underruns<=underruns+1'b1;state<=FAULT;
     sum=$signed(live)+(release_product>>>16);out_sample<=sat21(sum);
     release_gain<=release_gain>128?release_gain-128:0;
    end
    else begin
     sum=$signed(live)+$signed(preview);
     last_verified_audio<=preview;release_gain<=65536;
     out_sample<=sat21(sum);if(sum>1048575 || sum< -1048576)clip_events[0]=1;
     if(overdub || (od_pending && frame_od && position==0))begin
      if(!overdub)begin work_gen<=next_gen;next_gen<=next_gen+1'b1;overdub<=1;od_pending<=0;end
      od_product<=$signed(live)*$signed({1'b0,od_gain});od_old<=playback_sample;
      od_pipe_valid<=1;od_position<=position;od_last<=position==n-1;od_bank<=work_bank;od_generation<=overdub?work_gen:next_gen;
     end
     if(position==n-1)begin
      position<=0;
      if(overdub)begin overdub<=0;committing<=1;was_od<=1;end
      if(undo_pending && frame_undo)begin active_bank<=undo_bank;active_gen<=undo_gen;work_bank<=active_bank;undo_bank<=work_bank;undo_valid<=0;undo_pending<=0;end
      if(stop_pending && frame_stop)begin state<=STOPPED;stop_pending<=0;end
      if(clear_pending && frame_clear)begin state<=EMPTY;valid_loop<=0;undo_valid<=0;clear_pending<=0;end
     end else position<=position+1'b1;
    end
   end
  end
  if(command_valid && seq!=executed_seq)begin
   executed_seq<=seq;rejected<=0;
   case(op)
   1:if(state==EMPTY && !valid_loop && command[15:8]>=40 && command[15:8]<=240 &&
      (command[19:16]==1 || command[19:16]==2 || command[19:16]==4 || command[19:16]==8) && command[53:32]>0 && command[53:32]<=2304000)
      begin cfg_pending<=command;cfg_wait<=1;end else rejected<=1;
   2:if(state==ARM || state==COUNT || state==REC)begin state<=EMPTY;position<=0;end
     else if(state==EMPTY && memory_ready && !bridge_fault && !storage_fault && !test_active && !global_stop && !cfg_wait && next_gen!=32'hffffffff)state<=ARM;
     else rejected<=2;
   3:if(state==STOPPED && valid_loop && !test_active && !global_stop && !committing)begin play_pending<=!play_pending;position<=0;end else rejected<=2;
   4:if(playing && !committing && !stop_pending && !undo_pending && !clear_pending && next_gen!=32'hffffffff)begin
      if(overdub)begin overdub<=0;od_pipe_valid<=0;committing<=0;was_od<=0;end else od_pending<=!od_pending;
     end else rejected<=2;
   5:if(playing && !clear_pending)begin stop_pending<=!stop_pending;od_pending<=0;undo_pending<=0;end
     else if(state==ARM || state==COUNT || state==REC)begin state<=EMPTY;position<=0;end
     else if(state==STOPPED)play_pending<=0;else rejected<=2;
   6:if(undo_valid && !overdub && !committing && !stop_pending && !od_pending && !clear_pending)begin
      if(state==PLAY)undo_pending<=!undo_pending;
      else if(state==STOPPED)begin active_bank<=undo_bank;active_gen<=undo_gen;work_bank<=active_bank;undo_bank<=work_bank;undo_valid<=0;end
      else rejected<=2;
     end else rejected<=2;
   7:if(!overdub && state!=REC && !committing)begin
      if(playing)begin clear_pending<=!clear_pending;stop_pending<=0;od_pending<=0;undo_pending<=0;end
      else if(state==EMPTY || state==STOPPED || state==ARM || state==COUNT)begin state<=EMPTY;valid_loop<=0;undo_valid<=0;play_pending<=0;position<=0;end
      else rejected<=2;
     end else rejected<=2;
   8:if(!global_stop)click_on<=command[8];else rejected<=2;
   9:begin if(command[48:32]<=65536)target_gain<=command[48:32];if(command[80:64]<=65536)target_click_gain<=command[80:64];end
   10:if(state==FAULT && !bridge_fault && memory_ready && ready && store_idle)begin clear_fault<=1;local_fault<=0;state<=valid_loop?STOPPED:EMPTY;position<=0;end else rejected<=3;
   11:if(state!=EMPTY || valid_loop || !memory_ready)rejected<=2;
   12:if(command[63:32]<=32768)target_od_gain<=command[47:32];else rejected<=1;
   default:rejected<=4;
   endcase
  end
  if(storage_fault || bridge_fault)begin state<=FAULT;committing<=0;overdub<=0;od_pending<=0;stop_pending<=0;play_pending<=0;undo_pending<=0;clear_pending<=0;write_valid<=0;od_pipe_valid<=0;end
  if(!memory_ready)begin valid_loop<=0;undo_valid<=0;end
  if(local_fault)begin state<=FAULT;committing<=0;overdub<=0;od_pending<=0;stop_pending<=0;play_pending<=0;undo_pending<=0;clear_pending<=0;write_valid<=0;od_pipe_valid<=0;end
  if(command_valid && seq!=executed_seq && op==10 && state==FAULT && !bridge_fault && memory_ready && ready && store_idle)begin clear_fault<=1;local_fault<=0;recover_pending<=1;end
  if(recover_pending && !storage_fault && !local_fault)begin state<=valid_loop?STOPPED:EMPTY;position<=0;recover_pending<=0;end
  if(global_stop)begin
   state<=valid_loop?STOPPED:EMPTY;position<=0;overdub<=0;od_pending<=0;stop_pending<=0;play_pending<=0;undo_pending<=0;clear_pending<=0;committing<=0;write_valid<=0;od_pipe_valid<=0;click_on<=0;envelope<=0;
  end
  if(|clip_events)clips<=clips+{31'd0,clip_events[0]}+{31'd0,clip_events[1]};
 end
endmodule
