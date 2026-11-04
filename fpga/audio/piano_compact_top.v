// Standalone piano chain. No PLL, no legacy 16x16 output, no downstream mixer edits.
// key_state[0..31] = chromatic MIDI 41..72 (F2..C5). 1 = held.
// clk=49.152MHz; sample_ce=48kHz, one clk pulse, 1024 clocks apart.
// Input key state must be synchronous/debounced. Pulses shorter than a sample can be missed.
module piano_compact_top #(
parameter integer HEADROOM_BITS=2,
parameter MODAL_FILE="piano_modal.mem",
parameter NOISE_FILE="piano_noise.mem"
)(
input wire clk,rst_n,sample_ce,
input wire [159:0] note_bus,velocity_values,
input wire [127:0] channel_values,
input wire [287:0] channel_ratios,
input wire [31:0] key_state,
input wire [4:0] velocity_value,
output reg signed [18:0] modal_sample,noise_sample,
output reg frame_valid,
output wire busy,
output reg fault,output_clip,
output wire state_clip,
output wire [31:0] rejected_keys,
output wire [15:0] voice_active,
output wire [31:0] active_notes,
output reg [9:0] cycles_used
);
`include "piano_math.vh"
reg [159:0] sampled_notes,sampled_velocities;
reg [127:0] sampled_channels;
reg launch,started;
reg [31:0] sampled_keys;
reg [4:0] sampled_velocity;
wire scheduler_done;
wire [15:0] gate,strike,fresh,settled,modal_quiet,noise_quiet;
wire [79:0] keys,velocities;
reg [31:0] observed_notes;integer observe_i;
always @* begin observed_notes=0;for(observe_i=0;observe_i<16;observe_i=observe_i+1) if(voice_active[observe_i])observed_notes=observed_notes | (32'd1 << keys[observe_i*5+:5]);end
assign active_notes=observed_notes;

wire [111:0] damping;
wire modal_done,noise_done,modal_clip,noise_clip;
wire signed [39:0] modal_sum,noise_sum;
reg signed [39:0] modal_hold,noise_hold;
reg [1:0] seen;
reg [9:0] timer;
reg [31:0] rng;
wire [31:0] rng_a=rng^(rng<<13);
wire [31:0] rng_b=rng_a^(rng_a>>17);
wire [31:0] rng_c=rng_b^(rng_b<<5);
wire signed [23:0] random_base={{3{rng_c[31]}},rng_c[31:11]};
reg signed [23:0] white;
wire signed [52:0] modal_scaled=p_round(modal_hold,3+HEADROOM_BITS);
wire signed [52:0] noise_scaled=p_round(noise_hold,3+HEADROOM_BITS);
assign busy=started && !(&seen);
assign state_clip=modal_clip || noise_clip;
function signed [18:0] saturate19;
input signed [52:0] value;
begin
    if(value>53'sd262143)saturate19=19'sh3ffff;
    else if(value < -53'sd262144)saturate19=19'sh40000;
    else saturate19=value[18:0];
end
endfunction
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        launch<=0;started<=0;sampled_keys<=0;sampled_velocity<=0;modal_sample<=0;noise_sample<=0;
        frame_valid<=0;fault<=0;output_clip<=0;modal_hold<=0;noise_hold<=0;seen<=0;
        timer<=0;cycles_used<=0;rng<=32'd20260922;white<=0;
    end else begin
        launch<=0;frame_valid<=0;
        if(modal_done)begin modal_hold<=modal_sum;seen[0]<=1;end
        if(noise_done)begin noise_hold<=noise_sum;seen[1]<=1;end
        if(started && !(&seen) && timer!=1023)timer<=timer+1'b1;
        if((&(seen|{noise_done,modal_done})) && !(&seen))cycles_used<=timer+1'b1;
        if(sample_ce && !fault)begin
            if(started && !(&seen))fault<=1; // Never mix old/new frames on overrun.
            else begin
                if(started)begin
                    modal_sample<=saturate19(modal_scaled);noise_sample<=saturate19(noise_scaled);frame_valid<=1;
                    if(modal_scaled>262143 || modal_scaled < -262144 || noise_scaled>262143 || noise_scaled < -262144)output_clip<=1;
                end
                sampled_keys<=key_state;sampled_notes<=note_bus;sampled_velocities<=velocity_values;sampled_channels<=channel_values;sampled_velocity<=velocity_value;launch<=1;
                rng<=rng_c;white<=(random_base<<<1)+random_base+(random_base>>>1);
                started<=1;seen<=0;timer<=0;
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
piano_scheduler scheduler(.clk(clk),.rst_n(rst_n),.start(launch),.key_state(sampled_keys),.velocity_value(sampled_velocity),
 .note_bus(sampled_notes),.velocity_values(sampled_velocities),.channel_values(sampled_channels),.voice_channels(voice_channels),.modal_quiet(modal_quiet),.noise_quiet(noise_quiet),.busy(),.done(scheduler_done),.active(voice_active),
 .gate(gate),.strike(strike),.fresh(fresh),.settled(settled),.key_bus(keys),.velocity_bus(velocities),.damp_bus(damping),.rejected_keys(rejected_keys));
piano_modal_engine #(.PARAM_FILE(MODAL_FILE)) modal(.clk(clk),.rst_n(rst_n),.start(scheduler_done),
 .active(voice_active),.gate(gate),.strike(strike),.fresh(fresh),.settled(settled),.key_bus(keys),.velocity_bus(velocities),.damp_bus(damping),.voice_ratios(voice_ratios),
 .busy(),.done(modal_done),.overflow(modal_clip),.sum(modal_sum),.quiet(modal_quiet));
piano_noise_engine #(.PARAM_FILE(NOISE_FILE)) noise(.clk(clk),.rst_n(rst_n),.start(scheduler_done),
 .active(voice_active),.strike(strike),.fresh(fresh),.key_bus(keys),.velocity_bus(velocities),.white(white),
 .busy(),.done(noise_done),.overflow(noise_clip),.sum(noise_sum),.quiet(noise_quiet));
endmodule
