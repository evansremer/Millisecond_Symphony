`timescale 1ns/1ps
`default_nettype none
// Eleven sources, unified sampling boundary, unchanged 21-bit downstream chain.
// Audio core only: no DDR PHY, board wrapper, pin assignments or debug ports.
module audio_core #(
 parameter EQ_COEFF_FILE="eq_coeff_48k.mem",
 parameter [20:0] AGC_TARGET_MEAN=21'd524287,
 parameter integer AGC_IIR_SHIFT=8, AGC_CONTROL_SHIFT=4,
 parameter integer REVERB_MODE_STABLE_CYCLES=1024, I2S_BCLK_HALF_DIV=8,
 parameter integer ENABLE_THEREMIN=0, ENABLE_CONSOLE=0, SYNTH_VOICES=32, ENABLE_LOOP=0
)(
 input wire [127:0] loop_command,input wire loop_command_valid,output wire [511:0] loop_status,
    input wire loop_bridge_fault,
    output wire loop_request,loop_write,output wire [28:0] loop_address,output wire [255:0] loop_wdata,
    input wire loop_bus_ready,loop_response,loop_bus_error,input wire [255:0] loop_rdata,
 input wire loop_global_stop,loop_test_active,
 input wire console_stop,console_reseed,
 output wire [1023:0] console_status,
 input wire clk,rst_n,
 input wire loop_button,loop_memory_ready,
 output wire loop_req_valid,loop_req_write,
 input wire loop_req_ready,loop_rsp_valid,loop_rsp_error,
 output wire [21:0] loop_req_addr,
 output wire [31:0] loop_req_data,
 input wire [31:0] loop_rsp_data,
 input wire [159:0] note_bus,velocity_values,
input wire [127:0] channel_values,
input wire [287:0] channel_ratios,
 input wire [31:0] key_state,
 input wire [31:0] theremin_step,
 input wire [16:0] theremin_gain,theremin_mix,
 input wire [4:0] velocity_value,
 input wire [1:0] instrument_select,timbre_select,
 input wire [19:0] adsr_config,
 input wire adc_i2s_bck,adc_i2s_lrck,adc_i2s_din,
 input wire [17:0] adc_gain_left,adc_gain_right,
 input wire drum_hit_valid,
 output wire drum_hit_ready,
 input wire [3:0] drum_id,
 input wire [4:0] drum_velocity,
 input wire [2:0] eq_mode,
 input wire [1:0] reverb_mode,
 input wire [4:0] dry_pan_select,
 input wire [17:0] dry_gain,wet_gain,wet_width,master_gain,
 output wire pcm5102_bck,pcm5102_lrck,pcm5102_din,
 output wire signed [23:0] monitor_pcm_left,
 output wire signed [23:0] monitor_pcm_right,
 output wire audio_sample_ce,
 output wire monitor_pcm_valid
);
(* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [1:0] reset_release_sync;
always @(posedge clk or negedge rst_n)
 if(!rst_n)reset_release_sync<=0;else reset_release_sync<={reset_release_sync[0],1'b1};
wire sys_rst_n=reset_release_sync[1];
reg clear_sources,stop_cleared;
wire engine_reset_n=sys_rst_n && !(ENABLE_CONSOLE && (clear_sources || console_reseed));
wire sample_ce;
wire sample_tick,audio_fault,drum_invalid_hit,loop_fault;
wire [3:0] loop_state;
wire [21:0] loop_length;
assign sample_tick=sample_ce;
assign audio_sample_ce=sample_ce;
wire [31:0] piano_keys,horn_keys,synth_keys;
wire signed [18:0] horn_body,horn_modal,horn_noise,synth_audio;
wire horn_valid,horn_busy,horn_fault,synth_valid,synth_busy,synth_fault;
wire signed [18:0] piano_modal,piano_noise;
wire piano_valid,piano_busy,piano_fault,piano_output_clip,piano_state_clip;
wire [31:0] piano_rejected;
wire [15:0] piano_active,horn_active;
wire [SYNTH_VOICES-1:0] synth_active;
wire [31:0] piano_notes,horn_notes,synth_notes;
wire [16:0] laser_actual_gain,laser_actual_mix;
wire [9:0] piano_cycles_used;
wire [47:0] drum_bus;
wire drum_bus_valid,drum_core_ready,drum_fault;
wire [9:0] drum_cycles_used;
wire [33:0] external_audio_bus;
wire external_audio_valid,external_gain_busy,external_gain_overrun,external_format_error,external_pending_overrun;
wire [1:0] external_audio_clip;
wire [208:0] mixer_input_bus;
wire mixer_start,mixer_busy,mixer_overrun,mixer_clipped;
wire signed [20:0] mixed_sample,eq_sample,agc_audio;
wire mixed_valid,eq_valid,eq_ready,eq_busy,eq_overrun,eq_clipped,agc_audio_valid;
wire signed [20:0] performance_audio;
wire performance_valid,theremin_overrun;
wire signed [20:0] pre_agc_audio;
wire pre_agc_valid;
wire signed [20:0] loop_audio;
wire loop_valid,loop_clipped,loop_command_rejected;
wire [9:0] eq_cycles_used;
wire [2:0] eq_active_mode;
reg [2:0] eq_mode_internal;
wire [24:0] agc_gain_q24;
wire [20:0] agc_mean_level;
wire signed [20:0] reverb_dry,reverb_wet_left,reverb_wet_right;
wire reverb_out_valid,reverb_busy,reverb_init_done,reverb_frame_overrun,reverb_clip;
wire signed [20:0] stereo_audio_left,stereo_audio_right;
wire stereo_out_valid,stereo_busy,stereo_frame_overrun,stereo_clip;
wire fatal_audio_fault;
reg signed [23:0] pcm_left_hold,pcm_right_hold;
reg primed,frame_window,piano_ready,drum_ready,horn_ready,synth_ready,downstream_pending,pipeline_error;
assign fatal_audio_fault=pipeline_error || piano_fault || drum_fault || horn_fault || synth_fault || mixer_overrun || eq_overrun || theremin_overrun || reverb_frame_overrun || stereo_frame_overrun;
assign audio_fault=fatal_audio_fault;
assign drum_hit_ready=drum_core_ready && !fatal_audio_fault;
assign mixer_input_bus={
 synth_audio,horn_noise,horn_modal,horn_body,
 {{2{external_audio_bus[33]}},external_audio_bus[33:17]},
 {{2{external_audio_bus[16]}},external_audio_bus[16:0]},
 {{3{drum_bus[47]}},drum_bus[47:32]},{{3{drum_bus[31]}},drum_bus[31:16]},
 {{3{drum_bus[15]}},drum_bus[15:0]},piano_noise,piano_modal};
assign mixer_start=frame_window && piano_ready && drum_ready && horn_ready && synth_ready && !mixer_busy && !fatal_audio_fault;
// First boundary primes all engines. ADC need not produce a frame each tick.
always @(posedge clk or negedge engine_reset_n)begin
 if(!engine_reset_n)begin
  primed<=0;frame_window<=0;piano_ready<=0;drum_ready<=0;horn_ready<=0;synth_ready<=0;downstream_pending<=0;pipeline_error<=0;
 end else begin
  if(sample_ce)begin
   if(frame_window || downstream_pending)pipeline_error<=1;
   primed<=1;frame_window<=primed;piano_ready<=0;drum_ready<=0;horn_ready<=0;synth_ready<=0;
  end
  if(piano_valid)piano_ready<=1;
  if(drum_bus_valid)drum_ready<=1;
  if(horn_valid)horn_ready<=1;
  if(synth_valid)synth_ready<=1;
  if(mixer_start)begin frame_window<=0;downstream_pending<=1;end
  if(mixed_valid && !eq_ready)pipeline_error<=1;
  if(agc_audio_valid)downstream_pending<=0;
 end
end
instrument_key_router u_key_router(
 .clk(clk),.rst_n(engine_reset_n),.sample_ce(sample_ce),.instrument_select(instrument_select),.key_state(key_state),
 .piano_keys(piano_keys),.horn_keys(horn_keys),.synth_keys(synth_keys));
horn_compact_top u_horn_compact(
 .clk(clk),.rst_n(engine_reset_n),.sample_ce(sample_ce),.key_state(horn_keys),.velocity_value(velocity_value),.note_bus(note_bus),.velocity_values(velocity_values),.channel_values(channel_values),.channel_ratios(channel_ratios),
 .voice_active(horn_active),.active_notes(horn_notes),.body_sample(horn_body),.modal_sample(horn_modal),.noise_sample(horn_noise),.frame_valid(horn_valid),.busy(horn_busy),.fault(horn_fault));
synth_compact_top #(.VOICE_COUNT(SYNTH_VOICES)) u_synth_compact(
 .clk(clk),.rst_n(engine_reset_n),.sample_ce(sample_ce),.key_state(synth_keys),.velocity_value(velocity_value),.note_bus(note_bus),.velocity_values(velocity_values),.channel_values(channel_values),.channel_ratios(channel_ratios),.timbre_select(timbre_select),.adsr_config(adsr_config),
 .voice_active(synth_active),.active_notes(synth_notes),.audio_sample(synth_audio),.frame_valid(synth_valid),.busy(synth_busy),.fault(synth_fault));
piano_compact_top u_piano_compact(
 .clk(clk),.rst_n(engine_reset_n),.sample_ce(sample_ce),.key_state(piano_keys),.velocity_value(velocity_value),.note_bus(note_bus),.velocity_values(velocity_values),.channel_values(channel_values),.channel_ratios(channel_ratios),
 .modal_sample(piano_modal),.noise_sample(piano_noise),.frame_valid(piano_valid),.busy(piano_busy),
 .fault(piano_fault),.output_clip(piano_output_clip),.state_clip(piano_state_clip),
 .rejected_keys(piano_rejected),.active_notes(piano_notes),.voice_active(piano_active),.cycles_used(piano_cycles_used));
drum_compact_top u_drum_compact(
 .clk(clk),.rst_n(engine_reset_n),.sample_ce(sample_ce),
 .hit_valid(drum_hit_valid && !fatal_audio_fault),.hit_ready(drum_core_ready),.drum_id(drum_id),.velocity(drum_velocity),
 .drum_bus(drum_bus),.drum_bus_valid(drum_bus_valid),.mixed_sample(),.fault(drum_fault),
 .invalid_hit(drum_invalid_hit),.cycles_used(drum_cycles_used));
i2s_input_gain_top u_external_audio(
 .clk(clk),.rst_n(engine_reset_n),.sample_ce(sample_ce),.i2s_bck(adc_i2s_bck),.i2s_lrck(adc_i2s_lrck),.i2s_din(adc_i2s_din),
 .gain_left(adc_gain_left),.gain_right(adc_gain_right),.sample_bus(external_audio_bus),.sample_valid(external_audio_valid),
 .clipped(external_audio_clip),.gain_busy(external_gain_busy),.gain_overrun(external_gain_overrun),
 .format_error(external_format_error),.pending_overrun(external_pending_overrun));
mixer_sum_11 #(.KEYBOARD_PRE_SHIFT(2),.DRUM_PRE_SHIFT(2)) u_mixer_sum_11(
 .clk(clk),.rst_n(engine_reset_n),.start(mixer_start),.sample_bus(mixer_input_bus),
 .mixed_sample(mixed_sample),.mixed_valid(mixed_valid),.busy(mixer_busy),.overrun(mixer_overrun),.clipped(mixer_clipped));
always @* begin
 case(eq_mode)
  0:eq_mode_internal=2;1:eq_mode_internal=3;2:eq_mode_internal=4;3:eq_mode_internal=5;
  default:eq_mode_internal=0;
 endcase
end
eq_preset_bank #(.COEFF_FILE(EQ_COEFF_FILE)) u_eq_preset_bank(
 .clk(clk),.rst_n(engine_reset_n),.in_valid(mixed_valid),.in_sample(mixed_sample),.mode_select(eq_mode_internal),
 .in_ready(eq_ready),.out_valid(eq_valid),.out_sample(eq_sample),.busy(eq_busy),.overrun(eq_overrun),
 .clipped(eq_clipped),.cycles_used(eq_cycles_used),.active_mode(eq_active_mode));
agc_parallel_select_21 #(.PIPELINE_CONTROL(ENABLE_LOOP),.CLEAN_TARGET_MEAN(AGC_TARGET_MEAN),.IIR_SHIFT(AGC_IIR_SHIFT),.CONTROL_SHIFT(AGC_CONTROL_SHIFT)) u_agc_parallel_select_21(
 .clk(clk),.rst_n(engine_reset_n),.sample_ce(pre_agc_valid),.in_data(pre_agc_audio),.out_data(agc_audio),.out_valid(agc_audio_valid),
 .distortion_enable(eq_mode==3'd4),
 .clean_gain_q24(agc_gain_q24),.clean_mean_level(agc_mean_level),
 .distortion_gain_q24(),.distortion_mean_level(),.distortion_clip_pulse());
generate if (ENABLE_THEREMIN) begin:with_theremin
 theremin_voice_mixer u_theremin_voice_mixer(
  .clk(clk),.rst_n(engine_reset_n),.sample_ce(sample_ce),.phase_step(theremin_step),
  .target_gain(theremin_gain),.target_mix(theremin_mix),
  .in_valid(eq_valid),.in_sample(eq_sample),
  .out_valid(pre_agc_valid),.out_sample(pre_agc_audio),
  .actual_gain(laser_actual_gain),.actual_mix(laser_actual_mix),.busy(),.overrun(theremin_overrun));
end else begin:without_theremin
 assign laser_actual_gain=0;assign laser_actual_mix=0;
 assign pre_agc_audio=eq_sample;
 assign pre_agc_valid=eq_valid;
 assign theremin_overrun=1'b0;
end endgenerate
// Live sources share clean AGC or hard-clipping AGC (EQ selection 4). Loop playback
// remains downstream, so it cannot pump the recorded signal or feed back.
assign performance_audio=agc_audio;
assign performance_valid=agc_audio_valid;
wire signed [20:0] performance_gated;
reg [16:0] stop_gain;reg signed [38:0] stop_product;reg signed [20:0] stop_sample;reg stop_valid;
wire stopped=ENABLE_CONSOLE ? console_stop : 1'b0;
always @(posedge clk or negedge sys_rst_n)begin
 if(!sys_rst_n)begin clear_sources<=0;stop_cleared<=0;stop_gain<=65536;stop_valid<=0;stop_sample<=0;stop_product<=0;end
 else begin
  clear_sources<=0;
  if(!stopped)stop_cleared<=0;
  if(stopped && stop_gain==0 && !stop_cleared)begin clear_sources<=1;stop_cleared<=1;end
  if(sample_ce)begin
   if(stopped)stop_gain<=stop_gain>128?stop_gain-128:0;
   else stop_gain<=stop_gain<65408?stop_gain+128:65536;
  end
  if(performance_valid)stop_product<=$signed(performance_audio)*$signed({1'b0,stop_gain});
  stop_valid<=performance_valid;
  if(performance_valid)stop_sample<=performance_audio;
 end
end
// Dedicated gate adds one sample-data register cycle only in console builds.
assign performance_gated=stop_gain==65536?stop_sample:stop_product>>>16;
wire signed [20:0] loop_click;
generate if(ENABLE_LOOP)begin:quantized_loop
 // Fixed intra-frame slot: sources finish by cycle 222 in the integration
 // regression. This independent scheduler still supplies zero live PCM when
 // a source reseed suppresses its valid pulse; loop/beat position never stalls.
 reg [9:0] frame_age;reg frame_open,live_seen,scheduled_valid;
 reg signed [20:0] staged_live,scheduled_live;
 always @(posedge clk or negedge sys_rst_n)
 if(!sys_rst_n)begin frame_age<=0;frame_open<=0;live_seen<=0;staged_live<=0;scheduled_live<=0;scheduled_valid<=0;end
 else begin
  scheduled_valid<=0;
  if(sample_ce)begin frame_age<=0;frame_open<=1;live_seen<=0;end
  else if(frame_open)begin
   frame_age<=frame_age+1'b1;
   if(frame_age==254)begin scheduled_live<=live_seen?staged_live:21'sd0;scheduled_valid<=1;frame_open<=0;end
  end
  if(ENABLE_CONSOLE?stop_valid:performance_valid)begin staged_live<=ENABLE_CONSOLE?performance_gated:performance_audio;live_seen<=1;end
 end
 loop_transport transport(.clk(clk),.reset_n(sys_rst_n),.sample_ce(sample_ce),
  .in_valid(scheduled_valid),.live(scheduled_live),
  .global_stop(loop_global_stop),.test_active(loop_test_active),.memory_ready(loop_memory_ready),.bridge_fault(loop_bridge_fault),
  .command_valid(loop_command_valid),.command(loop_command),.executed_seq(),.rejected(),
  .out_valid(loop_valid),.out_sample(loop_audio),.click_sample(loop_click),.active(),.status(loop_status),
  .request(loop_request),.write(loop_write),.address(loop_address),.wdata(loop_wdata),
  .ready(loop_bus_ready),.response(loop_response),.error(loop_bus_error),.rdata(loop_rdata));
 assign loop_fault=0;assign loop_state=0;assign loop_length=0;assign loop_clipped=0;assign loop_command_rejected=0;
 assign loop_req_valid=0;assign loop_req_write=0;assign loop_req_addr=0;assign loop_req_data=0;
end else begin:legacy_loop
 assign loop_status=0;assign loop_request=0;assign loop_write=0;assign loop_address=0;assign loop_wdata=0;assign loop_click=0;
audio_loop u_audio_loop(
 .clk(clk),.rst_n(engine_reset_n),.in_valid(ENABLE_CONSOLE?stop_valid:performance_valid),.in_sample(ENABLE_CONSOLE?performance_gated:performance_audio),.button_pulse(loop_button),.memory_ready(loop_memory_ready),
 .out_valid(loop_valid),.out_sample(loop_audio),.state(loop_state),.loop_length(loop_length),.fault(loop_fault),
 .clipped(loop_clipped),.command_rejected(loop_command_rejected),
 .req_valid(loop_req_valid),.req_write(loop_req_write),.req_ready(loop_req_ready),.req_addr(loop_req_addr),.req_data(loop_req_data),
 .rsp_valid(loop_rsp_valid),.rsp_error(loop_rsp_error),.rsp_data(loop_rsp_data));
end endgenerate
reverb_stereo_preset #(.MODE_STABLE_CYCLES(REVERB_MODE_STABLE_CYCLES)) u_reverb(
 .clk(clk),.rst_n(sys_rst_n),.sample_ce(ENABLE_CONSOLE && stop_gain==0?sample_ce:loop_valid),.in_sample(ENABLE_CONSOLE && stop_gain==0?21'sd0:loop_audio),.mode_sel(reverb_mode),
 .wet_left(reverb_wet_left),.wet_right(reverb_wet_right),.dry_aligned(reverb_dry),.out_valid(reverb_out_valid),
 .busy(reverb_busy),.init_done(reverb_init_done),.frame_overrun(reverb_frame_overrun),.clip_detected(reverb_clip));
stereo_output_mixer #(.AUDIO_BITS(21),.GAIN_BITS(18),.PAN_BITS(5)) u_stereo_output(
 .clk(clk),.rst_n(sys_rst_n),.in_valid(reverb_out_valid),.dry_in(reverb_dry),
 .wet_left_in(reverb_wet_left),.wet_right_in(reverb_wet_right),.dry_pan_select(dry_pan_select),
 .dry_gain(dry_gain),.wet_gain(wet_gain),.wet_width(wet_width),.master_gain(master_gain),
 .out_valid(stereo_out_valid),.audio_left(stereo_audio_left),.audio_right(stereo_audio_right),
 .busy(stereo_busy),.frame_overrun(stereo_frame_overrun),.clip_detected(stereo_clip));
// Click bypasses reverb, follows independent gain and existing Q0.18 master.
wire signed [40:0] click_master_product=$signed(loop_click)*$signed({1'b0,master_gain});
wire signed [20:0] click_master_sample=click_master_product>>>18;
function signed [20:0] add_click;
 input signed [20:0] a,b;reg signed [21:0] v;
 begin v=$signed(a)+$signed(b);if(v>1048575)add_click=21'sh0fffff;else if(v< -1048576)add_click=21'sh100000;else add_click=v[20:0];end
endfunction
function signed [23:0] pcm_gain_x4;
 input signed [20:0] sample_in;
 reg signed [25:0] scaled_sample;
 begin
  scaled_sample=$signed({sample_in,5'b00000}); // Preserve previous final PCM x4.
  if(scaled_sample>26'sd8388607)pcm_gain_x4=24'sh7fffff;
  else if(scaled_sample < -26'sd8388608)pcm_gain_x4=24'sh800000;
  else pcm_gain_x4=scaled_sample[23:0];
 end
endfunction
always @(posedge clk or negedge sys_rst_n)begin
 if(!sys_rst_n)begin pcm_left_hold<=0;pcm_right_hold<=0;end
 else if(fatal_audio_fault)begin pcm_left_hold<=0;pcm_right_hold<=0;end
 else if(stereo_out_valid)begin pcm_left_hold<=pcm_gain_x4(add_click(stereo_audio_left,click_master_sample));pcm_right_hold<=pcm_gain_x4(add_click(stereo_audio_right,click_master_sample));end
end
i2s_tx_simple #(.SAMPLE_BITS(24),.SLOT_BITS(32),.BCLK_HALF_DIV(I2S_BCLK_HALF_DIV)) u_i2s_tx(
 .clk(clk),.rst_n(sys_rst_n),.pcm_left(pcm_left_hold),.pcm_right(pcm_right_hold),.sample_ce(sample_ce),
 .i2s_bclk(pcm5102_bck),.i2s_lrclk(pcm5102_lrck),.i2s_din(pcm5102_din));
 assign monitor_pcm_left=pcm_left_hold;
 assign monitor_pcm_right=pcm_right_hold;
 assign monitor_pcm_valid=stereo_out_valid;

reg [31:0] observed_samples;reg [23:0] peak_l,peak_r;reg [15:0] peak_timer;
reg [4:0] drum_visual[0:9];reg [31:0] accepted_drums;integer di;
// Display-only event pipeline isolates ready/fault routing from ten visual CEs.
reg visual_hit;reg [3:0] visual_id;reg [4:0] visual_velocity;
wire [23:0] abs_l=monitor_pcm_left[23] ? -monitor_pcm_left : monitor_pcm_left;
wire [23:0] abs_r=monitor_pcm_right[23] ? -monitor_pcm_right : monitor_pcm_right;
always @(posedge clk or negedge sys_rst_n)begin
 if(!sys_rst_n)begin observed_samples<=0;peak_l<=0;peak_r<=0;peak_timer<=0;accepted_drums<=0;visual_hit<=0;visual_id<=0;visual_velocity<=0;for(di=0;di<10;di=di+1)drum_visual[di]<=0;end
 else begin
  visual_hit<=drum_hit_valid && drum_hit_ready;
  if(drum_hit_valid && drum_hit_ready)begin visual_id<=drum_id;visual_velocity<=drum_velocity;end
  if(sample_ce)begin
   observed_samples<=observed_samples+1'b1;
   peak_timer<=peak_timer==799?0:peak_timer+1'b1;
   if(peak_timer==799)begin peak_l<=abs_l;peak_r<=abs_r;
    for(di=0;di<10;di=di+1)if(drum_visual[di]!=0)drum_visual[di]<=drum_visual[di]-1'b1;
   end else begin if(abs_l>peak_l)peak_l<=abs_l;if(abs_r>peak_r)peak_r<=abs_r;end
  end
  if(visual_hit && visual_id<10)begin drum_visual[visual_id]<=visual_velocity;accepted_drums<=accepted_drums+1'b1;end
 end
end
assign console_status[31:0]={horn_active,piano_active};
assign console_status[63:32]=synth_active;
assign console_status[95:64]=key_state;
assign console_status[127:96]=piano_notes|horn_notes|synth_notes;
assign console_status[159:128]={15'd0,laser_actual_gain};
assign console_status[191:160]={15'd0,laser_actual_mix};
assign console_status[223:192]={8'd0,peak_l};
assign console_status[255:224]={8'd0,peak_r};
assign console_status[287:256]={20'd0,stereo_clip,reverb_clip,eq_clipped,mixer_clipped,piano_output_clip,piano_state_clip,piano_fault,drum_fault,horn_fault,synth_fault,pipeline_error,fatal_audio_fault};
assign console_status[319:288]=observed_samples;
assign console_status[351:320]=theremin_step;
assign console_status[383:352]=accepted_drums;
genvar dv;generate for(dv=0;dv<10;dv=dv+1)begin:visual_drums
 assign console_status[(12+dv)*32+:32]={27'd0,drum_visual[dv]};
end endgenerate
assign console_status[1023:704]=0;

endmodule
`default_nettype wire
