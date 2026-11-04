// One ordered event per sample. Slots retain raw identity until NoteOff,
// including out-of-range/blocked notes, preventing retuning a held key.
module midi_audio_control #(parameter ENABLE_CONSOLE=0)(
 input performance_lock,
 input clk,rst_n,sample_ce,input [31:0] event_data,input event_valid,
 output event_ready,input [1:0] instrument,input signed [2:0] octave,
 output reg [31:0] key_state,output [159:0] key_notes,key_velocities,
 output [127:0] key_channels,output [287:0] channel_ratios,
 output reg drum_valid,input drum_ready,output reg [3:0] drum_id,
 output reg [4:0] drum_velocity,output reg note_kick,
 output reg [4:0] note_index,output playing,output [1:0] routed_instrument,
 output reg [31:0] range_rejected,slot_rejected
);
 wire locked=ENABLE_CONSOLE ? performance_lock : 1'b0;
 reg lock_previous;
 reg [31:0] used,blocked;
 reg [6:0] raw_note[0:31];
 reg [3:0] cable[0:31],channel[0:31];
 reg [4:0] pitch[0:31],velocity[0:31];
 reg [1:0] previous_instrument;
 reg signed [2:0] previous_octave;
 reg repeat_pending;reg [4:0] repeat_slot;
 reg [31:0] repeat_mask;
 reg [4:0] repeat_pitch;
 reg [4:0] repeat_velocity;
 wire [3:0] kind=event_data[31:28];
 wire drum_source=event_data[27];
 wire [3:0] ecable=event_data[26:23],echan=event_data[22:19];
 wire [6:0] enote=event_data[18:12],evel=event_data[6:0];
 wire config_change=instrument!=previous_instrument || octave!=previous_octave;
 wire signed [10:0] transposed=$signed({4'd0,enote})+$signed(octave)*11'sd12;
 wire found,free_found;reg [4:0] match_slot;
 wire [31:0] match_bits,match_select,free_select;
 integer j;
 function [4:0] velocity5;
  input [6:0] v;
  begin case(v)
   7'd0:velocity5=5'd0;
   7'd1:velocity5=5'd1;
   7'd2:velocity5=5'd1;
   7'd3:velocity5=5'd1;
   7'd4:velocity5=5'd1;
   7'd5:velocity5=5'd1;
   7'd6:velocity5=5'd1;
   7'd7:velocity5=5'd2;
   7'd8:velocity5=5'd2;
   7'd9:velocity5=5'd2;
   7'd10:velocity5=5'd2;
   7'd11:velocity5=5'd3;
   7'd12:velocity5=5'd3;
   7'd13:velocity5=5'd3;
   7'd14:velocity5=5'd3;
   7'd15:velocity5=5'd4;
   7'd16:velocity5=5'd4;
   7'd17:velocity5=5'd4;
   7'd18:velocity5=5'd4;
   7'd19:velocity5=5'd5;
   7'd20:velocity5=5'd5;
   7'd21:velocity5=5'd5;
   7'd22:velocity5=5'd5;
   7'd23:velocity5=5'd6;
   7'd24:velocity5=5'd6;
   7'd25:velocity5=5'd6;
   7'd26:velocity5=5'd6;
   7'd27:velocity5=5'd7;
   7'd28:velocity5=5'd7;
   7'd29:velocity5=5'd7;
   7'd30:velocity5=5'd7;
   7'd31:velocity5=5'd8;
   7'd32:velocity5=5'd8;
   7'd33:velocity5=5'd8;
   7'd34:velocity5=5'd8;
   7'd35:velocity5=5'd9;
   7'd36:velocity5=5'd9;
   7'd37:velocity5=5'd9;
   7'd38:velocity5=5'd9;
   7'd39:velocity5=5'd10;
   7'd40:velocity5=5'd10;
   7'd41:velocity5=5'd10;
   7'd42:velocity5=5'd10;
   7'd43:velocity5=5'd10;
   7'd44:velocity5=5'd11;
   7'd45:velocity5=5'd11;
   7'd46:velocity5=5'd11;
   7'd47:velocity5=5'd11;
   7'd48:velocity5=5'd12;
   7'd49:velocity5=5'd12;
   7'd50:velocity5=5'd12;
   7'd51:velocity5=5'd12;
   7'd52:velocity5=5'd13;
   7'd53:velocity5=5'd13;
   7'd54:velocity5=5'd13;
   7'd55:velocity5=5'd13;
   7'd56:velocity5=5'd14;
   7'd57:velocity5=5'd14;
   7'd58:velocity5=5'd14;
   7'd59:velocity5=5'd14;
   7'd60:velocity5=5'd15;
   7'd61:velocity5=5'd15;
   7'd62:velocity5=5'd15;
   7'd63:velocity5=5'd15;
   7'd64:velocity5=5'd16;
   7'd65:velocity5=5'd16;
   7'd66:velocity5=5'd16;
   7'd67:velocity5=5'd16;
   7'd68:velocity5=5'd17;
   7'd69:velocity5=5'd17;
   7'd70:velocity5=5'd17;
   7'd71:velocity5=5'd17;
   7'd72:velocity5=5'd18;
   7'd73:velocity5=5'd18;
   7'd74:velocity5=5'd18;
   7'd75:velocity5=5'd18;
   7'd76:velocity5=5'd19;
   7'd77:velocity5=5'd19;
   7'd78:velocity5=5'd19;
   7'd79:velocity5=5'd19;
   7'd80:velocity5=5'd20;
   7'd81:velocity5=5'd20;
   7'd82:velocity5=5'd20;
   7'd83:velocity5=5'd20;
   7'd84:velocity5=5'd21;
   7'd85:velocity5=5'd21;
   7'd86:velocity5=5'd21;
   7'd87:velocity5=5'd21;
   7'd88:velocity5=5'd21;
   7'd89:velocity5=5'd22;
   7'd90:velocity5=5'd22;
   7'd91:velocity5=5'd22;
   7'd92:velocity5=5'd22;
   7'd93:velocity5=5'd23;
   7'd94:velocity5=5'd23;
   7'd95:velocity5=5'd23;
   7'd96:velocity5=5'd23;
   7'd97:velocity5=5'd24;
   7'd98:velocity5=5'd24;
   7'd99:velocity5=5'd24;
   7'd100:velocity5=5'd24;
   7'd101:velocity5=5'd25;
   7'd102:velocity5=5'd25;
   7'd103:velocity5=5'd25;
   7'd104:velocity5=5'd25;
   7'd105:velocity5=5'd26;
   7'd106:velocity5=5'd26;
   7'd107:velocity5=5'd26;
   7'd108:velocity5=5'd26;
   7'd109:velocity5=5'd27;
   7'd110:velocity5=5'd27;
   7'd111:velocity5=5'd27;
   7'd112:velocity5=5'd27;
   7'd113:velocity5=5'd28;
   7'd114:velocity5=5'd28;
   7'd115:velocity5=5'd28;
   7'd116:velocity5=5'd28;
   7'd117:velocity5=5'd29;
   7'd118:velocity5=5'd29;
   7'd119:velocity5=5'd29;
   7'd120:velocity5=5'd29;
   7'd121:velocity5=5'd30;
   7'd122:velocity5=5'd30;
   7'd123:velocity5=5'd30;
   7'd124:velocity5=5'd30;
   7'd125:velocity5=5'd31;
   7'd126:velocity5=5'd31;
   7'd127:velocity5=5'd31;
   default:velocity5=0;
  endcase end
 endfunction
 function [4:0] drum_map;
  input [6:0] n;
  begin case(n)
   50:drum_map=0;48:drum_map=1;45:drum_map=2;35:drum_map=3;
   38:drum_map=4;37:drum_map=5;42:drum_map=6;46:drum_map=7;
   49:drum_map=8;51:drum_map=9;default:drum_map=31;
  endcase end
 endfunction
 genvar g;
 generate for(g=0;g<32;g=g+1)begin:pack_keys
  assign key_notes[g*5+:5]=pitch[g];
  assign key_velocities[g*5+:5]=velocity[g];
  assign key_channels[g*4+:4]=channel[g];
 end
 for(g=0;g<16;g=g+1)begin:pack_bend
  assign channel_ratios[g*18+:18]=18'd131072;
 end endgenerate
 assign playing=|key_state;
 assign routed_instrument=previous_instrument;
 assign event_ready=sample_ce && !config_change && (locked==lock_previous) && !repeat_pending && (!drum_valid || drum_ready);
 // Parallel identity comparisons; maintain original highest match priority.
 // Empty allocation uses lowest free slot directly, avoiding priority encode
 // followed by per-register dynamic-index decode on the slot write CE path.
 generate for(g=0;g<32;g=g+1)begin:select_slots
  assign match_bits[g]=used[g] && raw_note[g]==enote && cable[g]==ecable && channel[g]==echan;
  // Raw cable/channel/note identity is unique: allocation only occurs on
  // !found. No priority encoder belongs in the per-slot state write path.
  assign match_select[g]=match_bits[g];
  if(g==0)assign free_select[g]=!used[g];
  else assign free_select[g]=!used[g] && (&used[g-1:0]);
 end endgenerate
 assign found=|match_bits;
 assign free_found=!(&used);
 always @* begin
  match_slot=0;
  for(j=0;j<32;j=j+1)match_slot=match_slot | ({5{match_select[j]}} & j);
 end
 integer k;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   lock_previous<=0;key_state<=0;used<=0;blocked<=0;previous_instrument<=0;previous_octave<=0;
   repeat_pending<=0;repeat_slot<=0;repeat_velocity<=0;repeat_mask<=0;repeat_pitch<=0;
   drum_valid<=0;drum_id<=0;drum_velocity<=0;note_kick<=0;note_index<=0;
   range_rejected<=0;slot_rejected<=0;
   for(k=0;k<32;k=k+1)begin raw_note[k]<=0;cable[k]<=0;channel[k]<=0;pitch[k]<=0;velocity[k]<=0;end
  end else begin
   note_kick<=0;
   if(drum_valid && drum_ready)drum_valid<=0;
   if(sample_ce)begin
    previous_instrument<=instrument;previous_octave<=octave;lock_previous<=locked;
    if(locked)begin key_state<=0;blocked<=used;drum_valid<=0;repeat_pending<=0;end
    if(config_change || locked!=lock_previous)begin key_state<=0;blocked<=used;repeat_pending<=0;end
    else if(repeat_pending)begin
     repeat_pending<=0;
     if(!( |(blocked & repeat_mask)))begin
      key_state<=key_state | repeat_mask;
      for(k=0;k<32;k=k+1)if(repeat_mask[k])velocity[k]<=repeat_velocity;
      note_kick<=1;note_index<=repeat_pitch;
     end
    end else if(event_valid && event_ready)begin
     if(kind==4)begin
      if(drum_source)drum_valid<=0;
      else begin used<=0;blocked<=0;key_state<=0;end
     end else if(drum_source)begin
      if(!locked && kind==1 && evel!=0 && drum_map(enote)<10)begin drum_id<=drum_map(enote);drum_velocity<=velocity5(evel);drum_valid<=1;end
     end else if(kind==3)begin /* Reserved: MIDI bend ignored. */ end
     else if(kind==2 || (kind==1 && evel==0))begin
      if(found)begin key_state<=key_state & ~match_select;used<=used & ~match_select;blocked<=blocked & ~match_select;end
     end else if(kind==1 && evel!=0)begin
      if(found)begin
       if(!locked && !(|(blocked & match_select)))begin
        key_state<=key_state & ~match_select;repeat_pending<=1;
        repeat_slot<=match_slot;repeat_mask<=match_select;repeat_velocity<=velocity5(evel);
        for(k=0;k<32;k=k+1)if(match_select[k])repeat_pitch<=pitch[k];
       end
      end else if(free_found)begin
       used<=used | free_select;
       for(k=0;k<32;k=k+1)if(free_select[k])begin raw_note[k]<=enote;cable[k]<=ecable;channel[k]<=echan;velocity[k]<=velocity5(evel);end
       if(!locked && transposed>=41 && transposed<=72)begin
        for(k=0;k<32;k=k+1)if(free_select[k])pitch[k]<=transposed-41;
        key_state<=key_state | free_select;blocked<=blocked & ~free_select;note_index<=transposed-41;note_kick<=1;
       end else begin blocked<=blocked | free_select;if(!locked)range_rejected<=range_rejected+1'b1;end
      end else slot_rejected<=slot_rejected+1'b1;
     end
    end
   end
  end
 end
endmodule
