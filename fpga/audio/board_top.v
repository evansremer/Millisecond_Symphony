`timescale 1ns/1ps
`default_nettype none
// -----------------------------------------------------------------------------
// board_top ????Tang Mega 138K ???????????????
//
//   ???????????9 ????????????????? 10 ?????? ????? 32 ??????????//
// ?????//   clk 50 MHz ??????? Gowin_PLL_1080p ??71.667 MHz ??? / 358.333 MHz ?????????
//                ??? Gowin_PLL       ??49.15254 MHz ?????? PLL_INIT ?????//
// ?????//   ??? rst_n??????????????PLL ????????????????????????
//   ???????????????????????????????//
// ????????audio_gowin_hybrid_20261006 ?????top?????= ?????Q ?????//       ????????DC ??Loop ???????????tie-off??//
// ?????is_bars ?????? 440x1920 ?????????????//
// ???????????? board_top??????????????? top??????????// -----------------------------------------------------------------------------
module board_top(
    input wire [127:0] loop_command,input wire loop_command_valid,output wire [511:0] loop_status,
    input wire loop_memory_ready,loop_bridge_fault,
    output wire loop_request,loop_write,output wire [28:0] loop_address,output wire [255:0] loop_wdata,
    input wire loop_bus_ready,loop_response,loop_bus_error,input wire [255:0] loop_rdata,
    output wire console_sample_ce,input wire [127:0] console_config,input wire console_stop,output wire [1023:0] console_status,
 input wire [511:0] display_state,input wire display_ready,
 output wire console_frame_tick,output wire [11:0] console_tile_address,input wire [7:0] console_tile_data,
 input  wire       clk,          // 50 MHz??22
    input  wire       rst_n,        // ??????????????12
    input wire [31:0] midi_event_data,
    input wire midi_event_valid,output wire midi_event_ready,
    output wire audio_clock,output wire audio_reset_n,
    output wire ui_clock,ui_reset_n,
    output wire ui_theremin_enable,output wire [6:0] ui_theremin_mix,
    output wire [15:0] ui_theremin_config_seq,
    input wire [31:0] theremin_step,input wire [16:0] theremin_gain,theremin_mix,
    input  wire [1:0] key,          // ????????KEY0=AA13 / KEY1=AB13??????
    // Synchronous display-domain touch from the J18 USB-A host mailbox.
    input wire [2:0] touch_state,
    input wire touch_valid,touch_down,
    input wire [11:0] touch_x,touch_y,
    output wire       pcm5102_bck,
    output wire       pcm5102_lrck,
    output wire       pcm5102_din,
    output wire       tmds_clk_n_0,
    output wire       tmds_clk_p_0,
    output wire [2:0] tmds_d_n_0,
    output wire [2:0] tmds_d_p_0
);

    // =========================================================================
    // ???????????    // =========================================================================
    wire disp_clk;
    wire serial_clk;
    wire disp_lock;

    Gowin_PLL_1080p u_pll_disp (
        .lock    (disp_lock),
        .clkout0 (disp_clk),
        .clkout1 (serial_clk),
        .clkin   (clk)
    );

    reg [3:0] disp_rst_cnt;
    wire      disp_rst_n;
    always @(posedge disp_clk or negedge disp_lock) begin
        if (!disp_lock) disp_rst_cnt <= 4'd0;
        else            disp_rst_cnt <= disp_rst_cnt + !disp_rst_n;
    end
    assign disp_rst_n = &disp_rst_cnt;
    assign ui_clock=disp_clk;
    assign ui_reset_n=disp_rst_n;

    // =========================================================================
    // USB-A HID coordinates: X=0..439, Y=0..1919.    // =========================================================================
    // =========================================================================
    // ??????????????PLL_INIT ????????    // =========================================================================
    reg [7:0] startup_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                              startup_count <= 8'd0;
        else if (startup_count != 8'hFF)         startup_count <= startup_count + 1'b1;
    end
    wire pll_reset = !rst_n || (startup_count != 8'hFF);

    wire audio_clk;
    wire audio_lock;

    Audio_PLL u_pll_audio (
        .clkin    (clk),
        .init_clk (clk),
        .clkout0  (audio_clk),
        .lock     (audio_lock),
        .reset    (pll_reset)
    );

    wire audio_req_n = rst_n && audio_lock;
    reg  [1:0] audio_rst_sync;
    always @(posedge audio_clk or negedge audio_req_n) begin
        if (!audio_req_n) audio_rst_sync <= 2'b00;
        else              audio_rst_sync <= {audio_rst_sync[0], 1'b1};
    end
    wire audio_rst_n = audio_rst_sync[1];
    assign audio_clock=audio_clk;assign audio_reset_n=audio_rst_n;

    // =========================================================================
    // 48 kHz ??????49.152 MHz / 1024 = 48.000 kHz
    // ????????? I2S ??sample_ce ???????????????????????????????    // =========================================================================
    wire tick_48k;assign console_sample_ce=tick_48k;
    /* MIDI uses the actual I2S frame boundary.
    reg [9:0] tick_div;
    reg       tick_48k;
    always @(posedge audio_clk or negedge audio_rst_n) begin
        if (!audio_rst_n) begin
            tick_div <= 10'd0;
            tick_48k <= 1'b0;
        end else if (tick_div == 10'd1023) begin
            tick_div <= 10'd0;
            tick_48k <= 1'b1;
        end else begin
            tick_div <= tick_div + 1'b1;
            tick_48k <= 1'b0;
        end
    end

    // =========================================================================
    // ???????????
    // ??????????????????????????????????????? key_n = 0??    // =========================================================================
    */
    wire key_n = &key;

    wire [31:0] key_state;
    wire [4:0]  velocity;
    wire [1:0]  instrument_select;
    wire [3:0]  drum_id;
    wire [4:0]  drum_velocity;
    wire        drum_valid;
    wire        drum_ready;
    wire [1:0]  phase;
    wire        playing;
    wire [4:0]  note_index;
    wire        note_on;
    wire        note_kick;

    /* song_fsm u_song (
        .clk               (audio_clk),
        .rst_n             (audio_rst_n),
        .tick_48k          (tick_48k),
        .key_n             (key_n),
        .key_state         (key_state),
        .velocity          (velocity),
        .instrument_select (instrument_select),
        .drum_id           (drum_id),
        .drum_velocity     (drum_velocity),
        .drum_valid        (drum_valid),
        .drum_ready        (drum_ready),
        .playing           (playing),
        .note_index        (note_index),
        .note_on           (note_on),
        .note_kick         (note_kick),
        .phase             (phase)
    );

    // =========================================================================
    // ??????
    // =========================================================================
    */
    wire [21:0] dbg_loop_addr;
    wire [31:0] dbg_loop_data;

    // =========================================================================
    // UI ???????? 71.669 MHz -> ??? 49.152 MHz
    // ??????? toggle???????????????D-035?
    // =========================================================================
    wire [4:0]  p_adsr_a, p_adsr_d, p_adsr_s, p_adsr_r;
    wire [1:0] p_eq,p_reverb,p_timbre,p_instrument;
    wire signed [2:0] p_octave;
    wire [4:0]  p_pan;
    wire [17:0] p_dry, p_wet, p_width, p_master;

    wire signed [23:0] monitor_pcm_left, monitor_pcm_right;
    wire               monitor_pcm_valid;
    wire               spec_wr_en;
    wire [5:0]         spec_wr_addr;
    wire [9:0]         spec_wr_data;
    wire               spec_req, spec_ack;
    wire [5:0]         spec_rd_addr;
    wire [9:0]         spec_rd_data;
    wire               spec_display_valid;
    wire               spec_frame_tick;

    wire [107:0] cfg_audio=console_config[107:0];
    wire [1023:0] core_status;
    wire [31:0] range_rejected,slot_rejected;
    wire fft_capture_overrun,fft_result_overrun,fft_spec_drop,raw_drop;
    assign console_status={224'd0,28'd0,raw_drop,fft_spec_drop,fft_result_overrun,fft_capture_overrun,slot_rejected,range_rejected,core_status[703:0]};
    wire [5:0] test_count;wire fading,reseed,lock_inputs;
    wire test_active=test_count!=0;
    console_performance_switch performance_switch(.clk(audio_clk),.reset_n(audio_rst_n),.sample_ce(tick_48k),.stop(console_stop),
      .requested(console_config[113] && !console_stop?{console_config[114],console_config[112:108]}:6'd0),.active(test_count),.fading(fading),.reseed(reseed),.lock_inputs(lock_inputs));
    assign ui_theremin_enable=display_state[32];
    assign ui_theremin_mix=display_state[46:40];
    assign ui_theremin_config_seq=display_state[63:48];
    wire [31:0] test_keys;wire [159:0] test_notes,test_velocities;
    console_test_source u_console_test(.count(test_count),.key_state(test_keys),.notes(test_notes),.velocities(test_velocities));
    wire [159:0] midi_notes,midi_velocities;
    wire [127:0] midi_channels;
    wire [287:0] midi_ratios;
    midi_audio_control #(.ENABLE_CONSOLE(1)) u_midi_control(
      .performance_lock(lock_inputs),
      .clk(audio_clk),.rst_n(audio_rst_n),.sample_ce(tick_48k),
      .event_data(midi_event_data),.event_valid(midi_event_valid),.event_ready(midi_event_ready),
      .instrument(cfg_audio[107:106]),.octave(cfg_audio[105:103]),
      .key_state(key_state),.key_notes(midi_notes),.key_velocities(midi_velocities),
      .key_channels(midi_channels),.channel_ratios(midi_ratios),
      .drum_valid(drum_valid),.drum_ready(drum_ready),.drum_id(drum_id),.drum_velocity(drum_velocity),
      .note_kick(note_kick),.note_index(note_index),.playing(playing),.routed_instrument(instrument_select),.range_rejected(range_rejected),.slot_rejected(slot_rejected));
    assign velocity=5'd31;
    audio_core #(.ENABLE_THEREMIN(1),.ENABLE_CONSOLE(1),.ENABLE_LOOP(1)) u_audio (
        .loop_command(loop_command),.loop_command_valid(loop_command_valid),.loop_status(loop_status),
      .loop_memory_ready(loop_memory_ready),.loop_bridge_fault(loop_bridge_fault),
      .loop_request(loop_request),.loop_write(loop_write),.loop_address(loop_address),.loop_wdata(loop_wdata),
      .loop_bus_ready(loop_bus_ready),.loop_response(loop_response),.loop_bus_error(loop_bus_error),.loop_rdata(loop_rdata),
        .loop_global_stop(console_stop),.loop_test_active(test_active),
        .console_reseed(reseed),.console_stop(fading),.console_status(core_status),
        .clk                  (audio_clk),
        .rst_n                (audio_rst_n),
        // Loop ????????????????????? tie-off
        .loop_button          (1'b0),
        // loop_memory_ready connected above.
        .loop_req_valid       (),
        .loop_req_write       (),
        .loop_req_ready       (1'b1),
        .loop_rsp_valid       (1'b0),
        .loop_rsp_error       (1'b0),
        .loop_req_addr        (dbg_loop_addr),
        .loop_req_data        (dbg_loop_data),
        .loop_rsp_data        (32'd0),
        // ??????
        .audio_sample_ce(tick_48k),
        .theremin_step(theremin_step),.theremin_gain(test_active?17'd0:theremin_gain),.theremin_mix(test_active?17'd0:theremin_mix),
        .note_bus(test_active?test_notes:midi_notes),.velocity_values(test_active?test_velocities:midi_velocities),.channel_values(midi_channels),.channel_ratios(midi_ratios),
        .key_state            (test_active?test_keys:key_state),
        .velocity_value       (velocity),
        .instrument_select    (test_active?2'd2:instrument_select),
        .timbre_select        (test_active?2'd0:cfg_audio[78:77]),
        .adsr_config          (test_active?{5'd0,5'd0,5'd31,5'd1}:cfg_audio[102:83]),
        // ??? ADC?????????tie-off
        .adc_i2s_bck          (1'b0),
        .adc_i2s_lrck         (1'b0),
        .adc_i2s_din          (1'b0),
        .adc_gain_left        (18'd4096),
        .adc_gain_right       (18'd4096),
        .drum_hit_valid       (drum_valid),
        .drum_hit_ready       (drum_ready),
        .drum_id              (drum_id),
        .drum_velocity        (drum_velocity),
        // ?????Q ?????????????????????
        .eq_mode              (test_active?3'd3:{console_config[115], cfg_audio[82:81]}),
        .reverb_mode          (cfg_audio[80:79]),
        .dry_pan_select       (cfg_audio[76:72]),
        .dry_gain             (cfg_audio[71:54]),
        .wet_gain             (test_active?18'd0:cfg_audio[53:36]),
        .wet_width            (cfg_audio[35:18]),
        .master_gain          (test_active && cfg_audio[17:0]>18'd65536 ? 18'd65536:cfg_audio[17:0]),
        .pcm5102_bck          (pcm5102_bck),
        .pcm5102_lrck         (pcm5102_lrck),
        .pcm5102_din          (pcm5102_din),
        .monitor_pcm_left     (monitor_pcm_left),
        .monitor_pcm_right    (monitor_pcm_right),
        .monitor_pcm_valid    (monitor_pcm_valid)
    );

    // Read-only final-PCM FFT monitor.  It never feeds the audio chain.
    wire raw_bin_valid;wire [8:0] raw_bin_index,raw_read_index;wire [23:0] raw_bin_data,raw_read_data;
    fft_analyzer u_fft_analyzer (
        .raw_valid(raw_bin_valid),.raw_index(raw_bin_index),.raw_data(raw_bin_data),
        .clk             (audio_clk),
        .rst_n           (audio_rst_n),
        .pcm_left        (monitor_pcm_left),
        .pcm_right       (monitor_pcm_right),
        .pcm_valid       (monitor_pcm_valid),
        .busy            (),
        .capture_overrun (fft_capture_overrun),
        .result_overrun  (fft_result_overrun),
        .spec_wr_en      (spec_wr_en),
        .spec_wr_addr    (spec_wr_addr),
        .spec_wr_data    (spec_wr_data),
        .spec_req        (spec_req),
        .spec_ack        (spec_ack),
        .spec_drop       (fft_spec_drop),
        .frame_commit    ()
    );

    // =========================================================================
    // ??????????????? -> ???????????????toggle ??????
    // =========================================================================
    reg [4:0] kick_idx_a;
    reg       kick_tog_a;
    always @(posedge audio_clk or negedge audio_rst_n) begin
        if (!audio_rst_n) begin
            kick_idx_a <= 5'd0;
            kick_tog_a <= 1'b0;
        end else if (note_kick) begin
            kick_idx_a <= note_index;
            kick_tog_a <= ~kick_tog_a;
        end
    end

    reg [2:0] kick_sync;
    reg       kick_seen;
    reg [4:0] kick_idx_p;
    reg       playing_s1, playing_s2;

    always @(posedge disp_clk or negedge disp_rst_n) begin
        if (!disp_rst_n) begin
            kick_sync   <= 3'd0;
            kick_seen   <= 1'b0;
            kick_idx_p  <= 5'd0;
            playing_s1  <= 1'b0;
            playing_s2  <= 1'b0;
        end else begin
            kick_sync  <= {kick_sync[1:0], kick_tog_a};
            kick_seen  <= kick_sync[2];
            playing_s1 <= playing;
            playing_s2 <= playing_s1;
            if (kick_sync[2] != kick_seen) kick_idx_p <= kick_idx_a;
        end
    end
    wire kick_pulse_p = kick_sync[2] ^ kick_seen;

    // =========================================================================
    // ???
    // =========================================================================
    wire [23:0] dvi_data;
    wire        dvi_den;
    wire        dvi_hsync;
    wire        dvi_vsync;
    wire        dvi_line_start;

    reg dvi_vsync_d;
    always @(posedge disp_clk or negedge disp_rst_n) begin
        if (!disp_rst_n) dvi_vsync_d <= 1'b0;
        else             dvi_vsync_d <= dvi_vsync;
    end
    assign spec_frame_tick = dvi_vsync & ~dvi_vsync_d;

    spec_snapshot u_spec_snapshot (
        .audio_clk    (audio_clk),
        .audio_rst_n  (audio_rst_n),
        .wr_en        (spec_wr_en),
        .wr_addr      (spec_wr_addr),
        .wr_data      (spec_wr_data),
        .async_req    (spec_req),
        .ack          (spec_ack),
        .disp_clk     (disp_clk),
        .reset        (~disp_rst_n),
        .frame_tick   (spec_frame_tick),
        .rd_addr      (spec_rd_addr),
        .rd_data      (spec_rd_data),
        .valid        (spec_display_valid)
    );

    assign console_frame_tick=spec_frame_tick;
    console_fft_store raw_store(.aclk(audio_clk),.uclk(disp_clk),.reset_n(audio_rst_n && disp_rst_n),
      .wr_valid(raw_bin_valid),.wr_index(raw_bin_index),.wr_data(raw_bin_data),
      .frame_tick(spec_frame_tick),.freeze(display_state[248]),.read_index(raw_read_index),.read_data(raw_read_data),.have_frame(),.dropped(raw_drop));
    wire [13:0] xy_address;wire xy_pixel;
    // Visualization only: original final PCM still feeds DAC, FFT and meters.
    reg phase_input_valid;
    always @(posedge audio_clk or negedge audio_rst_n)
      if(!audio_rst_n)phase_input_valid<=0;else phase_input_valid<=monitor_pcm_valid;
    wire signed [23:0] phase_left,phase_right;wire phase_valid;
    wire phase_overrun,phase_clipped;
    lissajous_phase_bank12 u_liss_phase12(.clk(audio_clk),.rst_n(audio_rst_n),
      .in_valid(phase_input_valid),.in_left(monitor_pcm_left),.in_right(monitor_pcm_right),
      .out_valid(phase_valid),.out_left(phase_left),.out_right(phase_right),
      .busy(),.overrun(phase_overrun),.clipped(phase_clipped));
    lissajous_trace u_lissajous(.audio_clk(audio_clk),.pixel_clk(disp_clk),.reset_n(audio_rst_n && disp_rst_n),
      .pcm_left(phase_left),.pcm_right(phase_right),.pcm_valid(phase_valid),
      .frame_tick(spec_frame_tick),.read_address(xy_address),.trace_pixel(xy_pixel),.have_frame());
    console_video u_console_video(.pixel_clock(disp_clk),.reset(~disp_rst_n),.ready(display_ready),.state(display_state),
      .xy_pixel(xy_pixel),.xy_address(xy_address),
      .frame_tick(),.tile_address(console_tile_address),.tile_data(console_tile_data),
      .spec_level(spec_rd_data),.spec_addr(spec_rd_addr),.raw_level(raw_read_data),.raw_addr(raw_read_index),
      .video_pixel(dvi_data),.video_den(dvi_den),.video_hsync(dvi_hsync),.video_vsync(dvi_vsync),.video_line_start(dvi_line_start));

    dvi_tx_top u_dvi (
        .pixel_clock   (disp_clk),
        .ddr_bit_clock (serial_clk),
        .reset         (~disp_rst_n),
        .den           (dvi_den),
        .hsync         (dvi_hsync),
        .vsync         (dvi_vsync),
        .pixel_data    (dvi_data),
        .tmds_clk      ({tmds_clk_p_0, tmds_clk_n_0}),
        .tmds_d0       ({tmds_d_p_0[0], tmds_d_n_0[0]}),
        .tmds_d1       ({tmds_d_p_0[1], tmds_d_n_0[1]}),
        .tmds_d2       ({tmds_d_p_0[2], tmds_d_n_0[2]})
    );

endmodule
`default_nettype wire
