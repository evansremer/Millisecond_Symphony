// 32 chromatic keys, 16 fixed voice slots. No per-hit voice/state duplication.
// Inputs are synchronous, debounced and stable at start. Each changed key is handled.
// New presses within the same sampled mask share velocity_value.
module piano_scheduler #(parameter integer VOICE_COUNT=16, parameter integer VOICE_BITS=$clog2(VOICE_COUNT))(
input wire clk,rst_n,start,
input wire [31:0] key_state,
input wire [4:0] velocity_value,
input wire [159:0] note_bus,velocity_values,
input wire [127:0] channel_values,
output reg [VOICE_COUNT*4-1:0] voice_channels,
input wire [VOICE_COUNT-1:0] modal_quiet,noise_quiet,
output reg busy,done,
output reg [VOICE_COUNT-1:0] active,gate,strike,fresh,settled,
output reg [VOICE_COUNT*5-1:0] key_bus,velocity_bus,
output reg [VOICE_COUNT*7-1:0] damp_bus,
output reg [31:0] rejected_keys
);
reg [31:0] previous_keys,snapshot;
reg [4:0] sampled_velocity,key_index;
reg [159:0] notes_snapshot,velocities_snapshot;
reg [127:0] channels_snapshot;
reg [4:0] slot_id[0:VOICE_COUNT-1];
reg [VOICE_BITS-1:0] voice_index;
reg [1:0] state;
reg [11:0] age[0:VOICE_COUNT-1]; // Only a saturating 50 ms cleanup guard, not note history.
reg found,free_found;
reg [VOICE_BITS-1:0] found_voice,free_voice;
integer j,k;
wire [VOICE_COUNT-1:0] match_bits,match_select,free_select;
genvar slot;
generate for(slot=0;slot<VOICE_COUNT;slot=slot+1)begin:select_slot
 assign match_bits[slot]=active[slot] && slot_id[slot]==key_index;
 if(slot==VOICE_COUNT-1)assign match_select[slot]=match_bits[slot];
 else assign match_select[slot]=match_bits[slot] && !(|match_bits[VOICE_COUNT-1:slot+1]);
 if(slot==0)assign free_select[slot]=!active[slot];
 else assign free_select[slot]=!active[slot] && (&active[slot-1:0]);
end endgenerate
always @* begin
 found=|match_bits;free_found=!(&active);found_voice=0;free_voice=0;
 for(j=0;j<VOICE_COUNT;j=j+1)begin
  found_voice=found_voice | ({VOICE_BITS{match_select[j]}} & j);
  free_voice=free_voice | ({VOICE_BITS{free_select[j]}} & j);
 end
end
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        state<=0;busy<=0;done<=0;previous_keys<=0;snapshot<=0;sampled_velocity<=0;
        active<=0;gate<=0;strike<=0;fresh<=0;settled<=0;key_bus<=0;velocity_bus<=0;
        damp_bus<=0;rejected_keys<=0;key_index<=0;voice_index<=0;
        voice_channels<=0;notes_snapshot<=0;velocities_snapshot<=0;channels_snapshot<=0;
        for(k=0;k<VOICE_COUNT;k=k+1)begin age[k]<=0;slot_id[k]<=0;end
    end else begin
        done<=0;
        case(state)
        0:if(start)begin
            busy<=1;state<=1;snapshot<=key_state;sampled_velocity<=velocity_value;
            notes_snapshot<=note_bus;velocities_snapshot<=velocity_values;channels_snapshot<=channel_values;
            strike<=0;fresh<=0;rejected_keys<=0;key_index<=0;
            for(k=0;k<VOICE_COUNT;k=k+1)
                if(active[k] && !gate[k] && modal_quiet[k] && noise_quiet[k] && !key_state[slot_id[k]])active[k]<=0;
        end
        1:begin
            if(snapshot[key_index]!=previous_keys[key_index])begin
                if(!snapshot[key_index])begin if(found)gate[found_voice]<=0;end
                else if(velocities_snapshot[key_index*5+:5]!=0)begin
                    if(found)begin
                        gate[found_voice]<=1;strike[found_voice]<=1;
                        fresh[found_voice]<=key_bus[found_voice*5+:5]!=notes_snapshot[key_index*5+:5];
                        velocity_bus[found_voice*5 +:5]<=velocities_snapshot[key_index*5+:5];
                        key_bus[found_voice*5+:5]<=notes_snapshot[key_index*5+:5];
                        voice_channels[found_voice*4+:4]<=channels_snapshot[key_index*4+:4];
                    end else if(free_found)begin
                        active[free_voice]<=1;gate[free_voice]<=1;strike[free_voice]<=1;fresh[free_voice]<=1;
                        key_bus[free_voice*5 +:5]<=notes_snapshot[key_index*5+:5];slot_id[free_voice]<=key_index;
                        voice_channels[free_voice*4+:4]<=channels_snapshot[key_index*4+:4];
                        velocity_bus[free_voice*5 +:5]<=velocities_snapshot[key_index*5+:5];
                    end else rejected_keys[key_index]<=1;
                end
            end
            if(key_index==31)begin state<=2;voice_index<=0;previous_keys<=snapshot;end
            else key_index<=key_index+1'b1;
        end
        2:begin
            if(!active[voice_index] || strike[voice_index])begin age[voice_index]<=0;settled[voice_index]<=0;end
            else begin
                if(age[voice_index]<2400)age[voice_index]<=age[voice_index]+1'b1;
                settled[voice_index]<=age[voice_index]>=2399;
            end
            if(gate[voice_index] || !active[voice_index])damp_bus[voice_index*7 +:7]<=0;
            else if(damp_bus[voice_index*7 +:7]<96)damp_bus[voice_index*7 +:7]<=damp_bus[voice_index*7 +:7]+1'b1;
            if(voice_index==VOICE_COUNT-1)begin state<=0;busy<=0;done<=1;end
            else voice_index<=voice_index+1'b1;
        end
        default:state<=0;
        endcase
    end
end
endmodule
