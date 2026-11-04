// 16-voice independent advanced French horn, 32 keys F2..C5 / MIDI 41..72.
// Publish last computed frame on sample_ce, matching original piano/drum timing.
module horn_compact_top(
input wire clk,rst_n,sample_ce,
input wire [159:0] note_bus,velocity_values,
input wire [127:0] channel_values,
input wire [287:0] channel_ratios,
input wire [31:0] key_state,
input wire [4:0] velocity_value,
output reg signed [18:0] body_sample,modal_sample,noise_sample,
output reg frame_valid,
output wire [15:0] voice_active,output wire [31:0] active_notes,
output wire busy,
output reg fault
);
reg [159:0] sampled_notes,sampled_velocities;
reg [127:0] sampled_channels;
reg launch,started;reg [31:0] keys_in;reg [4:0] velocity_in;
wire scheduler_done,env_done,body_done,modal_done,noise_done;
wire modal_overflow,noise_overflow;
wire [15:0] active,gate,strike,quiet;
wire [79:0] keys,velocities;
reg [31:0] observed_notes;integer observe_i;
always @* begin observed_notes=0;for(observe_i=0;observe_i<16;observe_i=observe_i+1) if(active[observe_i])observed_notes=observed_notes | (32'd1 << keys[observe_i*5+:5]);end
assign active_notes=observed_notes;
assign voice_active=active;

wire [111:0] parameter_ids,table_ids;
wire [511:0] phases;
wire [863:0] envelopes;
wire [1199:0] releases;
wire [399:0] transients;
wire [287:0] velocity_gains;
wire [383:0] whites;
wire signed [35:0] body_sum,modal_sum,noise_sum;
reg signed [35:0] body_hold,modal_hold,noise_hold;
reg [2:0] seen;
assign busy=started && !(&seen);
function signed [18:0] sat19;
input signed [35:0] x;
begin if(x>262143)sat19=19'sh3ffff;else if(x< -262144)sat19=19'sh40000;else sat19=x[18:0];end
endfunction
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin launch<=0;started<=0;keys_in<=0;velocity_in<=0;seen<=0;
   body_sample<=0;modal_sample<=0;noise_sample<=0;frame_valid<=0;fault<=0;
   body_hold<=0;modal_hold<=0;noise_hold<=0;
 end else begin
   launch<=0;frame_valid<=0;
   if(body_done)begin body_hold<=body_sum;seen[0]<=1;end
   if(modal_done)begin modal_hold<=modal_sum;seen[1]<=1;end
   if(noise_done)begin noise_hold<=noise_sum;seen[2]<=1;end
   if(modal_overflow || noise_overflow)fault<=1;
   if(sample_ce && !fault)begin
     if(started && !(&seen))fault<=1;
     else begin
       if(started)begin body_sample<=sat19(body_hold);modal_sample<=sat19(modal_hold);noise_sample<=sat19(noise_hold);frame_valid<=1;end
       keys_in<=key_state;sampled_notes<=note_bus;sampled_velocities<=velocity_values;sampled_channels<=channel_values;velocity_in<=velocity_value;launch<=1;started<=1;seen<=0;
     end
   end
 end
end
wire [63:0] voice_channels;
wire [287:0] voice_ratios;
genvar bend_voice;
generate for(bend_voice=0;bend_voice<16;bend_voice=bend_voice+1)begin:select_bend
 assign voice_ratios[bend_voice*18+:18]=channel_ratios[voice_channels[bend_voice*4+:4]*18+:18];
end endgenerate
piano_scheduler scheduler(.clk(clk),.rst_n(rst_n),.start(launch),.key_state(keys_in),.velocity_value(velocity_in),
 .note_bus(sampled_notes),.velocity_values(sampled_velocities),.channel_values(sampled_channels),.voice_channels(voice_channels),.modal_quiet(quiet),.noise_quiet(quiet),.busy(),.done(scheduler_done),.active(active),.gate(gate),.strike(strike),
 .fresh(),.settled(),.key_bus(keys),.velocity_bus(velocities),.damp_bus(),.rejected_keys());
horn_envelopes fitted_envelopes(.clk(clk),.rst_n(rst_n),.start(scheduler_done),.active(active),.gate(gate),.strike(strike),
 .keys(keys),.velocities(velocities),.voice_ratios(voice_ratios),.done(env_done),.quiet(quiet),.parameter_ids(parameter_ids),.table_ids(table_ids),
 .phases(phases),.envelopes(envelopes),.releases(releases),.transients(transients),.velocity_gains(velocity_gains),.whites(whites));
horn_body body(.clk(clk),.rst_n(rst_n),.start(env_done),.table_ids(table_ids),.phases(phases),.envelopes(envelopes),
 .releases(releases),.velocity_gains(velocity_gains),.done(body_done),.sum(body_sum));
horn_modal modal(.clk(clk),.rst_n(rst_n),.start(env_done),.active(active),.strike(strike),.parameter_ids(parameter_ids),
 .releases(releases),.velocity_gains(velocity_gains),.voice_ratios(voice_ratios),.done(modal_done),.overflow(modal_overflow),.sum(modal_sum));
horn_noise noise(.clk(clk),.rst_n(rst_n),.start(env_done),.active(active),.strike(strike),.parameter_ids(parameter_ids),
 .envelopes(envelopes),.releases(releases),.transients(transients),.velocity_gains(velocity_gains),.whites(whites),
 .done(noise_done),.overflow(noise_overflow),.sum(noise_sum));
endmodule
