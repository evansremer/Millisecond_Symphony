`timescale 1ns/1ps
`default_nettype none
// -----------------------------------------------------------------------------
// vis_bars   1920x440  90  440x1920 
//
//    (px, py) ->  (lx, ly)lx = 1919 - py, ly = px
//
//   12 rows * 52 px = 624 px; 440 visible, 184 px scroll range.
//          16 
//            x 1152..1632480  8 px 20x20 x 1664
//            x 1152..1792 x 1168
//          16x322 
//
//    y  scroll_y = 
//          ly = touch_x
//
//   den/hsync/vsync/line_start 
// -----------------------------------------------------------------------------
module vis_bars #(
    parameter [16:0] CONTACT_SAMPLE_DIV = 17'd71666
)(
    input  wire        pixel_clock,
    input  wire        reset,
    input  wire [4:0]  kick_index,
    input  wire        kick_pulse,
    input  wire        playing,
    input  wire [11:0] touch_x,
    input  wire [11:0] touch_y,
    input  wire        touch_down,
    input  wire        touch_valid,
    input  wire [2:0]  touch_state,
    input  wire [9:0]  spec_level,
    output wire [5:0]  spec_addr,
    output wire [4:0]  p_adsr_a,
    output wire [4:0]  p_adsr_d,
    output wire [4:0]  p_adsr_s,
    output wire [4:0]  p_adsr_r,
    output wire [1:0]  p_eq,
    output wire [1:0]  p_reverb,
    output wire [1:0] p_timbre,p_instrument,
    output reg signed [2:0] p_octave,
    output reg p_theremin_enable,
    output reg [6:0] p_theremin_mix,
    output reg [15:0] p_theremin_config_seq,
    output wire [4:0]  p_pan,
    output wire [17:0] p_dry,
    output wire [17:0] p_wet,
    output wire [17:0] p_width,
    output wire [17:0] p_master,
    output wire [23:0] video_pixel,
    output wire        video_den,
    output wire        video_hsync,
    output wire        video_vsync,
    output wire        video_line_start
);

    localparam [9:0]  SCROLL_MAX = 10'd288;   // 12 * 52 - 440
    localparam [10:0] MAX_LEN    = 11'd1912;
    localparam [10:0] DECAY      = 11'd32;

    // Exact row=floor(y/52) for the 14-row settings canvas.  A threshold
    // decoder is smaller than the former constant multipliers and frees the
    // three half-DSP blocks used by display/touch coordinate helpers.
    function [3:0] row_from_y;
        input [10:0] y;
        begin
            if      (y >= 11'd676) row_from_y = 4'd13;
            else if (y >= 11'd624) row_from_y = 4'd12;
            else if (y >= 11'd572) row_from_y = 4'd11;
            else if (y >= 11'd520) row_from_y = 4'd10;
            else if (y >= 11'd468) row_from_y = 4'd9;
            else if (y >= 11'd416) row_from_y = 4'd8;
            else if (y >= 11'd364) row_from_y = 4'd7;
            else if (y >= 11'd312) row_from_y = 4'd6;
            else if (y >= 11'd260) row_from_y = 4'd5;
            else if (y >= 11'd208) row_from_y = 4'd4;
            else if (y >= 11'd156) row_from_y = 4'd3;
            else if (y >= 11'd104) row_from_y = 4'd2;
            else if (y >= 11'd52)  row_from_y = 4'd1;
            else                   row_from_y = 4'd0;
        end
    endfunction

    wire [13:0] pixel_x, pixel_y, timing_h_pos;
    wire        raw_vsync, raw_hsync, raw_den, raw_line_start;

    video_timing_ctrl #(
        .VIDEO_H_LENGTH (540), .VIDEO_V_LENGTH (2209),
        .VIDEO_HSYNC_POL(1),   .VIDEO_HSYNC_LEN(20),
        .VIDEO_HBP_LEN  (40),  .VIDEO_H_VISIBLE(440),
        .VIDEO_VSYNC_POL(1),   .VIDEO_VSYNC_LEN(4),
        .VIDEO_VBP_LEN  (12),  .VIDEO_V_VISIBLE(1920)
    ) u_timing (
        .pixel_clock(pixel_clock), .reset(reset),
        .timing_h_pos(timing_h_pos), .timing_v_pos(),
        .pixel_x(pixel_x), .pixel_y(pixel_y),
        .video_vsync(raw_vsync), .video_hsync(raw_hsync),
        .video_den(raw_den), .video_line_start(raw_line_start)
    );

    // ---- ------------------------------------
    (* ram_style = "registers" *) reg [10:0] level [0:31];
    reg [31:0] kick_mask;
    reg        vsync_d;
    wire frame_tick = raw_vsync & ~vsync_d;
    wire [31:0] kick_now = kick_mask | (kick_pulse ? (32'd1 << kick_index) : 32'd0);

    integer i;
    always @(posedge pixel_clock) begin
        if (reset) begin
            for (i = 0; i < 32; i = i + 1) level[i] <= 11'd0;
            kick_mask <= 32'd0; vsync_d <= 1'b0;
        end else begin
            vsync_d <= raw_vsync;
            if (frame_tick)      kick_mask <= 32'd0;
            else if (kick_pulse) kick_mask <= kick_mask | (32'd1 << kick_index);
            if (frame_tick) begin
                for (i = 0; i < 32; i = i + 1) begin
                    if (kick_now[i])             level[i] <= MAX_LEN;
                    else if (level[i] > DECAY)   level[i] <= level[i] - DECAY;
                    else                         level[i] <= 11'd0;
                end
            end
        end
    end

    // ----  -----------------------------------
    reg [9:0]  scroll_y;
    reg        page_settings;
    reg        page_theremin;
    reg        page_gesture;
    reg        mode_slider;
    reg        mode_select;
    reg [3:0]  lat_row;
    reg        drag_on;
    reg [9:0]  last_ly;
    reg        contact_active;
    reg [2:0]  contact_filter_count;
    reg [16:0] contact_sample_div;

    // touch_down is held between CH569 reports, so debounce it at a fixed
    // 1 kHz sample rate instead of requiring the panel to repeat reports.
    // Eight stable samples confirm either edge (about 8 ms hysteresis).
    wire contact_sample_tick = (contact_sample_div == CONTACT_SAMPLE_DIV);
    wire touch_press   = contact_sample_tick &&  touch_down && !contact_active &&
                         (contact_filter_count == 3'd7);
    wire touch_move    = touch_valid &&  touch_down &&  contact_active;
    wire touch_release = contact_sample_tick && !touch_down &&  contact_active &&
                         (contact_filter_count == 3'd7);

    wire [9:0]  tly  = touch_x[9:0];
    wire [9:0]  dly  = (tly > last_ly) ? (tly - last_ly) : (last_ly - tly);
    wire        down = (tly > last_ly);
    wire [11:0] sc_inc = {2'b00, scroll_y} + dly;
    wire [11:0] sc_dec = {2'b00, scroll_y} - dly;

    always @(posedge pixel_clock) begin
        if (reset) begin
            scroll_y <= 8'd0; drag_on <= 1'b0; last_ly <= 10'd0;
        end else if (touch_press) begin
            last_ly <= tly;
            drag_on <= 1'b1;
        end else if (touch_move) begin
            last_ly <= tly;
            if (page_settings && !page_gesture) begin
                if (mode_slider || mode_select) begin
                    drag_on <= 1'b1;
                end else if (down) begin
                    //     scroll 
                    scroll_y <= sc_dec[11] ? 10'd0 : sc_dec[9:0];
                end else begin
                    //     scroll 
                    scroll_y <= (sc_inc > {2'b00, SCROLL_MAX}) ? SCROLL_MAX : sc_inc[9:0];
                end
            end
        end else if (touch_release) begin
            drag_on <= 1'b0;
        end
    end

    // ----  ------------------------------------------------
    reg [9:0] sval [0:13];      //  0..1023
    reg [1:0] selv [0:13];      // 
    reg [10:0] knob_cache [0:13];
    reg [7:0]  pct_cache [0:13];
    reg [3:0]  tens_cache [0:13];
    reg [3:0]  ones_cache [0:13];
    reg        full_cache [0:13];
    integer k;

    function [10:0] slider_knob;
        input [9:0] value;
        reg [13:0] value_x11;
        begin
            value_x11 = ({4'd0, value} << 3) + ({4'd0, value} << 1) + value;
            slider_knob = 11'd320 + {1'b0, value} + value_x11[13:6];
        end
    endfunction

    function [7:0] slider_percent;
        input [9:0] value;
        reg [14:0] value_x25;
        begin
            value_x25 = ({5'd0, value} << 4) + ({5'd0, value} << 3) + value;
            slider_percent = (value == 10'd1023) ? 8'd100 : value_x25[14:8];
        end
    endfunction

    function [3:0] percent_tens;
        input [7:0] value;
        begin
            if      (value >= 8'd90) percent_tens = 4'd9;
            else if (value >= 8'd80) percent_tens = 4'd8;
            else if (value >= 8'd70) percent_tens = 4'd7;
            else if (value >= 8'd60) percent_tens = 4'd6;
            else if (value >= 8'd50) percent_tens = 4'd5;
            else if (value >= 8'd40) percent_tens = 4'd4;
            else if (value >= 8'd30) percent_tens = 4'd3;
            else if (value >= 8'd20) percent_tens = 4'd2;
            else if (value >= 8'd10) percent_tens = 4'd1;
            else                     percent_tens = 4'd0;
        end
    endfunction

    function [3:0] percent_ones;
        input [7:0] value;
        reg [3:0] tens;
        begin
            tens = percent_tens(value);
            percent_ones = value - {tens, 3'b000} - {tens, 1'b0};
        end
    endfunction

    wire [10:0] t_lx = 11'd1919 - touch_y[10:0];
    wire [9:0]  t_ly = touch_x[9:0];
    // Two fixed page buttons, both in absolute display coordinates:
    // SETTINGS at lx 1744..1887, ly 16..111; HOME at ly 128..223.
    // They are separate level actions, not a toggle, so repeated press
    // reports on the same button cannot flip the page back and forth.
    wire page_settings_hit = (t_lx >= 11'd1744) && (t_lx < 11'd1888) &&
                             (t_ly >= 10'd16)  && (t_ly < 10'd112);
    wire page_home_hit = (t_lx >= 11'd1744) && (t_lx < 11'd1888) &&
                         (t_ly >= 10'd128) && (t_ly < 10'd224);
    // A third fixed navigation button opens the independent theremin panel.
    // It does not enlarge or shift the existing fourteen-row settings canvas.
    wire page_theremin_hit = (t_lx >= 11'd1744) && (t_lx < 11'd1888) &&
                             (t_ly >= 10'd240) && (t_ly < 10'd336);
    wire theremin_off_hit = (t_lx >= 11'd320) && (t_lx < 11'd660) &&
                             (t_ly >= 10'd104) && (t_ly < 10'd168);
    wire theremin_on_hit = (t_lx >= 11'd680) && (t_lx < 11'd1020) &&
                             (t_ly >= 10'd104) && (t_ly < 10'd168);
    wire theremin_minus_hit = (t_lx >= 11'd320) && (t_lx < 11'd660) &&
                             (t_ly >= 10'd216) && (t_ly < 10'd280);
    wire theremin_plus_hit = (t_lx >= 11'd1020) && (t_lx < 11'd1360) &&
                             (t_ly >= 10'd216) && (t_ly < 10'd280);
    wire theremin_config_hit = (t_lx >= 11'd320) && (t_lx < 11'd1020) &&
                             (t_ly >= 10'd336) && (t_ly < 10'd400);
    wire [10:0] t_cy = t_ly + scroll_y;
    wire [3:0]  t_row = row_from_y(t_cy);
    wire        t_is_sel = (t_row == 4'd4) || (t_row == 4'd5) || (t_row == 4'd11) || (t_row == 4'd12) || (t_row == 4'd13);
    wire        t_in_track = (t_lx >= 11'd320) && (t_lx < 11'd1520);
    wire        t_in_box   = (t_lx >= 11'd320) && (t_lx < 11'd1680);
    wire [10:0] t_dx  = t_in_track ? (t_lx - 11'd320) : 11'd0;
    // floor(x * 437 / 512) = x - ceil(x * 75 / 512).
    // This exact narrow form avoids a wide multiplier in the touch path.
    reg [10:0] t_dx_q;
    always @(posedge pixel_clock) t_dx_q <= t_dx;
    wire [17:0] t_dx_w = {7'd0, t_dx_q};
    wire [17:0] t_sub_mul = (t_dx_w << 6) + (t_dx_w << 3) +
                             (t_dx_w << 1) + t_dx_w;
    wire [8:0]  t_sub = (t_sub_mul + 18'd511) >> 9;
    wire [10:0] t_pos_w = t_dx_q - t_sub;
    wire [9:0]  t_pos = t_pos_w[9:0];              // 0..1199 -> 0..1023
    reg  [9:0]  t_pos_q;
    reg         slider_sample_pending;
    reg  [3:0]  slider_sample_row;
    reg slider_sample_commit;reg [3:0] slider_commit_row;
    wire [1:0] t_sel_opt = (t_lx < 11'd660)  ? 2'd0 :
                           (t_lx < 11'd1000) ? 2'd1 :
                           (t_lx < 11'd1340) ? 2'd2 : 2'd3;

    always @(posedge pixel_clock) begin
        if (reset) begin
            sval[0]  <= 10'd396;  sval[1]  <= 10'd660;  sval[2]  <= 10'd792;
            sval[3]  <= 10'd594;  sval[4]  <= 10'd512;  sval[5]  <= 10'd512;
            sval[6]  <= 10'd528;  sval[7]  <= 10'd1023; sval[8]  <= 10'd256;
            sval[9]  <= 10'd1023; sval[10] <= 10'd819;  sval[11] <= 10'd727;
            sval[12] <= 10'd512;  sval[13] <= 10'd614;
            knob_cache[0]  <= slider_knob(10'd396);  pct_cache[0]  <= slider_percent(10'd396);
            knob_cache[1]  <= slider_knob(10'd660);  pct_cache[1]  <= slider_percent(10'd660);
            knob_cache[2]  <= slider_knob(10'd792);  pct_cache[2]  <= slider_percent(10'd792);
            knob_cache[3]  <= slider_knob(10'd594);  pct_cache[3]  <= slider_percent(10'd594);
            knob_cache[4]  <= slider_knob(10'd512);  pct_cache[4]  <= slider_percent(10'd512);
            knob_cache[5]  <= slider_knob(10'd512);  pct_cache[5]  <= slider_percent(10'd512);
            knob_cache[6]  <= slider_knob(10'd528);  pct_cache[6]  <= slider_percent(10'd528);
            knob_cache[7]  <= slider_knob(10'd1023); pct_cache[7]  <= slider_percent(10'd1023);
            knob_cache[8]  <= slider_knob(10'd256);  pct_cache[8]  <= slider_percent(10'd256);
            knob_cache[9]  <= slider_knob(10'd1023); pct_cache[9]  <= slider_percent(10'd1023);
            knob_cache[10] <= slider_knob(10'd819);  pct_cache[10] <= slider_percent(10'd819);
            knob_cache[11] <= slider_knob(10'd727);  pct_cache[11] <= slider_percent(10'd727);
            knob_cache[12] <= slider_knob(10'd512);  pct_cache[12] <= slider_percent(10'd512);
            knob_cache[13] <= slider_knob(10'd614);  pct_cache[13] <= slider_percent(10'd614);
            tens_cache[0]  <= percent_tens(slider_percent(10'd396));
            tens_cache[1]  <= percent_tens(slider_percent(10'd660));
            tens_cache[2]  <= percent_tens(slider_percent(10'd792));
            tens_cache[3]  <= percent_tens(slider_percent(10'd594));
            tens_cache[4]  <= percent_tens(slider_percent(10'd512));
            tens_cache[5]  <= percent_tens(slider_percent(10'd512));
            tens_cache[6]  <= percent_tens(slider_percent(10'd528));
            tens_cache[7]  <= percent_tens(slider_percent(10'd1023));
            tens_cache[8]  <= percent_tens(slider_percent(10'd256));
            tens_cache[9]  <= percent_tens(slider_percent(10'd1023));
            tens_cache[10] <= percent_tens(slider_percent(10'd819));
            tens_cache[11] <= percent_tens(slider_percent(10'd727));
            tens_cache[12] <= percent_tens(slider_percent(10'd512));
            tens_cache[13] <= percent_tens(slider_percent(10'd614));
            ones_cache[0]  <= percent_ones(slider_percent(10'd396));
            ones_cache[1]  <= percent_ones(slider_percent(10'd660));
            ones_cache[2]  <= percent_ones(slider_percent(10'd792));
            ones_cache[3]  <= percent_ones(slider_percent(10'd594));
            ones_cache[4]  <= percent_ones(slider_percent(10'd512));
            ones_cache[5]  <= percent_ones(slider_percent(10'd512));
            ones_cache[6]  <= percent_ones(slider_percent(10'd528));
            ones_cache[7]  <= percent_ones(slider_percent(10'd1023));
            ones_cache[8]  <= percent_ones(slider_percent(10'd256));
            ones_cache[9]  <= percent_ones(slider_percent(10'd1023));
            ones_cache[10] <= percent_ones(slider_percent(10'd819));
            ones_cache[11] <= percent_ones(slider_percent(10'd727));
            ones_cache[12] <= percent_ones(slider_percent(10'd512));
            ones_cache[13] <= percent_ones(slider_percent(10'd614));
            for (k = 0; k < 14; k = k + 1) full_cache[k] <= (k == 7) || (k == 9);
            p_octave<=0;
            p_theremin_enable<=1'b0;
            p_theremin_mix<=7'd25;
            p_theremin_config_seq<=16'd0;
            for (k = 0; k < 14; k = k + 1) selv[k] <= 2'd0;
            contact_active <= 1'b0;
            contact_filter_count <= 3'd0;
            contact_sample_div <= 17'd0;
            mode_slider <= 1'b0;
            mode_select <= 1'b0;
            lat_row <= 4'd0;
            page_settings <= 1'b0;
            page_theremin <= 1'b0;
            page_gesture <= 1'b0;
            t_pos_q <= 10'd0;
            slider_sample_pending <= 1'b0;
            slider_sample_row <= 4'd0;
            slider_sample_commit <= 0;slider_commit_row <= 0;
        end else begin
            if (contact_sample_tick) begin
                contact_sample_div <= 17'd0;
                if (touch_down == contact_active) begin
                    contact_filter_count <= 3'd0;
                end else if (contact_filter_count == 3'd7) begin
                    contact_active <= touch_down;
                    contact_filter_count <= 3'd0;
                end else begin
                    contact_filter_count <= contact_filter_count + 1'b1;
                end
            end else begin
                contact_sample_div <= contact_sample_div + 1'b1;
            end
            t_pos_q <= t_pos;
            slider_sample_commit <= slider_sample_pending;
            slider_commit_row <= slider_sample_row;
            slider_sample_pending <= 1'b0;
            if (slider_sample_commit) begin
                case (slider_commit_row)
                    4'd0: sval[0] <= t_pos_q;
                    4'd1: sval[1] <= t_pos_q;
                    4'd2: sval[2] <= t_pos_q;
                    4'd3: sval[3] <= t_pos_q;
                    4'd4: sval[4] <= t_pos_q;
                    4'd5: sval[5] <= t_pos_q;
                    4'd6: sval[6] <= t_pos_q;
                    4'd7: sval[7] <= t_pos_q;
                    4'd8: sval[8] <= t_pos_q;
                    4'd9: sval[9] <= t_pos_q;
                    4'd10: sval[10] <= t_pos_q;
                    4'd11: sval[11] <= t_pos_q;
                    4'd12: sval[12] <= t_pos_q;
                    4'd13: sval[13] <= t_pos_q;
                    default: ;
                endcase
            end
            for (k = 0; k < 14; k = k + 1) begin
                if (k == lat_row) begin
                    knob_cache[k] <= slider_knob(sval[k]);
                    pct_cache[k]  <= slider_percent(sval[k]);
                    tens_cache[k] <= percent_tens(slider_percent(sval[k]));
                    ones_cache[k] <= percent_ones(slider_percent(sval[k]));
                    full_cache[k] <= (sval[k] == 10'd1023);
                end
            end
            if (touch_press) begin
                mode_slider <= 1'b0;
                mode_select <= 1'b0;
                lat_row     <= t_row;
                if (!page_gesture && page_settings_hit) begin
                    // Level action: repeated presses on SETTINGS cannot leave
                    // SETTINGS, and cannot toggle back to MAIN.
                    page_settings <= 1'b1;
                    page_theremin <= 1'b0;
                    page_gesture  <= 1'b1;
                end else if (!page_gesture && page_home_hit) begin
                    // Level action: repeated presses on HOME cannot leave MAIN.
                    page_settings <= 1'b0;
                    page_theremin <= 1'b0;
                    page_gesture  <= 1'b1;
                end else if (!page_gesture && page_theremin_hit) begin
                    page_settings <= 1'b0;
                    page_theremin <= 1'b1;
                    page_gesture <= 1'b1;
                end else if (page_theremin && !page_gesture) begin
                    if (theremin_off_hit) p_theremin_enable <= 1'b0;
                    if (theremin_on_hit) p_theremin_enable <= 1'b1;
                    if (theremin_minus_hit && p_theremin_mix >= 7'd5)
                        p_theremin_mix <= p_theremin_mix - 7'd5;
                    if (theremin_plus_hit && p_theremin_mix <= 7'd95)
                        p_theremin_mix <= p_theremin_mix + 7'd5;
                    // Only a debounced fresh press writes persistent sensor
                    // settings. Holding or sliding into SET90HZ never repeats.
                    if (theremin_config_hit)
                        p_theremin_config_seq <= p_theremin_config_seq + 1'b1;
                end else if (page_settings && !page_gesture) begin
                    mode_select <= t_in_box && t_is_sel;
                    mode_slider <= (t_in_track && !t_is_sel);
                    if (t_in_track && !t_is_sel) begin
                        slider_sample_pending <= 1'b1;
                        slider_sample_row <= t_row;
                    end
                    if (t_in_box && t_is_sel) begin
                        for (k = 0; k < 14; k = k + 1)
                            if (k == t_row && t_row!=13) selv[k] <= (t_row==12 && t_sel_opt==3)?2'd2:t_sel_opt;
                        if(t_row==13)begin
                          if(t_sel_opt==0 && p_octave> -3)p_octave<=p_octave-1'b1;
                          if(t_sel_opt==3 && p_octave<3)p_octave<=p_octave+1'b1;
                        end
                    end
                end
            end else if (page_settings && !page_gesture && touch_move &&
                         mode_slider && t_in_track) begin
                slider_sample_pending <= 1'b1;
                slider_sample_row <= lat_row;
            end else if (touch_release) begin
                mode_slider <= 1'b0;
                mode_select <= 1'b0;
                page_gesture <= 1'b0;
            end
        end
    end

    // ----  ----------------------------------------------------------
    wire [10:0] lx = 11'd1919 - pixel_y[10:0];
    wire [9:0]  ly = pixel_x[9:0];

    reg [10:0] lx_r, lx_2;
    reg [9:0]  ly_r, ly_2;
    reg        den_r, hs_r, vs_r, ls_r;
    reg        den_2, hs_2, vs_2, ls_2;
    reg        den_3, hs_3, vs_3, ls_3;
    reg [3:0]  row_r;
    reg [10:0] thumb_r;
    reg [10:0] t_lx2, t_ly2;
    reg        t_d2;
    reg [2:0]  t_state2;
    reg        page_r, page_2;
    reg        theremin_r, theremin_2;
    reg [6:0]  bar_slot_q;
    reg [5:0]  bar_freq_q;
    wire [6:0] bar_req_slot;
    wire [5:0] bar_req_freq;

    wire [10:0] lyc = {1'b0, ly_r} + scroll_y;   // 
    wire [3:0] row_calc = row_from_y(lyc);
    // scroll * 176 / 184, represented as (scroll * 979) >> 10.
    // 979 = 1024 - 32 - 8 - 4 - 1; shift/add only, no DSP.
    wire [19:0] scroll_w = {10'd0, scroll_y};
    wire [19:0] thumb_sub = (scroll_w << 5) + (scroll_w << 3) +
                            (scroll_w << 2) + scroll_w;
    wire [19:0] thumbmul = (scroll_w << 10) - thumb_sub;

    always @(posedge pixel_clock) begin
        if (reset) begin
            lx_r <= 0; ly_r <= 0; lx_2 <= 0; ly_2 <= 0; row_r <= 4'd0; thumb_r <= 11'd0;
            t_lx2 <= 0; t_ly2 <= 0; t_d2 <= 0; t_state2 <= 0;
            page_r <= 1'b0; page_2 <= 1'b0;
            theremin_r <= 1'b0; theremin_2 <= 1'b0;
            bar_slot_q <= 7'd0;
            bar_freq_q <= 6'd63;
            den_r <= 0; hs_r <= 0; vs_r <= 0; ls_r <= 0;
            den_2 <= 0; hs_2 <= 0; vs_2 <= 0; ls_2 <= 0;
            den_3 <= 0; hs_3 <= 0; vs_3 <= 0; ls_3 <= 0;
        end else begin
            lx_r  <= lx;
            ly_r  <= ly;
            den_r <= raw_den; hs_r <= raw_hsync; vs_r <= raw_vsync; ls_r <= raw_line_start;

            row_r  <= row_calc;
            thumb_r <= thumbmul[19:10];
            bar_slot_q <= bar_req_slot;
            bar_freq_q <= bar_req_freq;
            lx_2   <= lx_r;
            ly_2   <= ly_r;
            den_2  <= den_r; hs_2 <= hs_r; vs_2 <= vs_r; ls_2 <= ls_r;
            t_lx2  <= 11'd1919 - touch_y[10:0];
            t_ly2  <= touch_x[9:0];
            t_d2   <= touch_down;
            t_state2 <= touch_state;
            page_r <= page_settings;
            page_2 <= page_r;
            theremin_r <= page_theremin;
            theremin_2 <= theremin_r;

            den_3  <= den_2; hs_3 <= hs_2; vs_3 <= vs_2; ls_3 <= ls_2;
        end
    end

    // 
    wire [9:0] row52 = {1'b0, row_r, 5'b00000} + {2'b00, row_r, 4'b0000} + {4'b0000, row_r, 2'b00};
    wire [9:0] lyo   = ly_2 + scroll_y - row52;
    wire [9:0] lyot  = lyo - 10'd10;

    // ----  ------------------------------------------------------------
    function [6:0] label_char;
        input [3:0] row;
        input [5:0] col;
        reg [127:0] s;
        begin
            case (row)
                4'd0:    s = "ADSR  A         ";
                4'd1:    s = "ADSR  D         ";
                4'd2:    s = "ADSR  S         ";
                4'd3:    s = "ADSR  R         ";
                4'd4:    s = "EQ              ";
                4'd5:    s = "REVERB          ";
                4'd6:    s = "PAN             ";
                4'd7:    s = "DRY             ";
                4'd8:    s = "WET             ";
                4'd9:    s = "WIDTH           ";
                4'd10:   s = "MASTER          ";
                4'd11:   s = "TIMBRE          ";
                4'd12:   s = "INSTRUMENT      ";
                4'd13:   s = "OCTAVE          ";
                default: s = "                ";
            endcase
            label_char = (col < 6'd16) ? s[127 - col*8 -: 8] : 7'd32;
        end
    endfunction

    function [6:0] value_char;
        input [3:0] row;
        input [5:0] col;
        reg [127:0] s;
        begin
            case (row)
                4'd0:    s = "12              ";
                4'd1:    s = "20              ";
                4'd2:    s = "24              ";
                4'd3:    s = "18              ";
                4'd4:    s = "PRESET 1        ";
                4'd5:    s = "HALL            ";
                4'd6:    s = "CENTER          ";
                4'd7:    s = "100%            ";
                4'd8:    s = "25%             ";
                4'd9:    s = "100%            ";
                4'd10:   s = "80%             ";
                4'd11:   s = "SINE            ";
                4'd12:   s = "OFF             ";
                4'd13:   s = "120BPM          ";
                default: s = "                ";
            endcase
            value_char = (col < 6'd8) ? s[127 - col*8 -: 8] : 7'd32;
        end
    endfunction

    function [6:0] page_button_char;
        input        is_settings;
        input [3:0]  col;
        reg [63:0] s;
        begin
            if (is_settings) s = "SETTINGS";
            else             s = "HOME    ";
            page_button_char = (col < 6'd8) ? s[63 - col*8 -: 8] : 7'd32;
        end
    endfunction

    function [10:0] knob_x;
        input [3:0] row;
        begin
            case (row)
                4'd0:    knob_x = 11'd784;    // A  12/31
                4'd1:    knob_x = 11'd1094;   // D  20/31
                4'd2:    knob_x = 11'd1249;   // S  24/31
                4'd3:    knob_x = 11'd1017;   // R  18/31
                4'd6:    knob_x = 11'd939;    // PAN 
                4'd7:    knob_x = 11'd1520;   // DRY 100%
                4'd8:    knob_x = 11'd620;    // WET 25%
                4'd9:    knob_x = 11'd1520;   // WIDTH 100%
                4'd10:   knob_x = 11'd1280;   // MASTER 80%
                4'd11:   knob_x = 11'd1172;   // VELOCITY 22/31
                4'd13:   knob_x = 11'd1040;   // TEMPO 120/200
                default: knob_x = 11'd320;
            endcase
        end
    endfunction

    wire sel_row = (row_r == 4'd4) || (row_r == 4'd5) || (row_r == 4'd11) || (row_r == 4'd12) || (row_r == 4'd13);

    // ----  ----------------------------------------------------------
    wire [10:0] lxo  = lx_2 - 11'd32;
    wire [2:0]  tgx  = lxo[3:1];
    wire [3:0]  tgy  = lyot[4:1];
    wire [5:0]  lcol = lxo[10:4];

    wire [10:0] vorig = 11'd1552;
    wire [10:0] lxvo  = lx_2 - vorig;
    wire [5:0]  vcol  = lxvo[10:4];

    wire in_label = (lx_2 >= 11'd32) && (lx_2 < 11'd288) &&
                    (lyo >= 10'd10) && (lyo < 10'd42);
    wire in_value = !sel_row && (lx_2 >= vorig) && (lx_2 < (vorig + 11'd128)) &&
                    (lyo >= 10'd10) && (lyo < 10'd42);

    //  mux RAM
    reg [9:0]  sval_sel;
    reg [1:0]  sel_cur;
    reg [10:0] knob_pos;
    reg [7:0]  pct_sel;
    reg [3:0]  ptens;
    reg [3:0]  pones;
    reg        full;
    integer jj;
    always @(*) begin
        sval_sel = 0;
        sel_cur  = 0;
        knob_pos = 0;
        pct_sel  = 0;
        ptens    = 0;
        pones    = 0;
        full     = 1'b0;
        for (jj = 0; jj < 14; jj = jj + 1) begin
            // Parallel one-hot selection avoids a fourteen-row priority chain.
            sval_sel = sval_sel | (sval[jj] & {10{row_r==jj}});
            sel_cur = sel_cur | (selv[jj] & {2{row_r==jj}});
            knob_pos = knob_pos | (knob_cache[jj] & {11{row_r==jj}});
            pct_sel = pct_sel | (pct_cache[jj] & {8{row_r==jj}});
            ptens = ptens | (tens_cache[jj] & {4{row_r==jj}});
            pones = pones | (ones_cache[jj] & {4{row_r==jj}});
            full = full | (full_cache[jj] & (row_r==jj));
        end
    end

    wire [7:0] pct = pct_sel;

    wire [6:0] c0 = full ? 7'd49 : 7'd32;
    wire [6:0] c1 = 7'd48 + (full ? 4'd0 : ptens);
    wire [6:0] c2 = 7'd48 + (full ? 4'd0 : pones);
    wire [6:0] c3 = 7'd37;

    reg [6:0] slider_char;
    always @(*) begin
        case (vcol)
            6'd0:    slider_char = c0;
            6'd1:    slider_char = c1;
            6'd2:    slider_char = c2;
            6'd3:    slider_char = c3;
            default: slider_char = 7'd32;
        endcase
    end

    function [6:0] sel_option_char;
        input [3:0] row;
        input [5:0] col;
        input [1:0] opt;
        reg [63:0] s;
        begin
            if (row == 4'd4) begin
                case (opt)
                    2'd0: s = "PRESET 1";
                    2'd1: s = "PRESET 2";
                    2'd2: s = "PRESET 3";
                    default: s = "BYPASS  ";
                endcase
            end else if (row == 4'd5) begin
                case (opt)
                    2'd0: s = "HALL    ";
                    2'd1: s = "ROOM    ";
                    2'd2: s = "PLATE   ";
                    default: s = "OFF     ";
                endcase
            end else if(row==12)begin
                case(opt)
                 0:s="PIANO   ";1:s="HORN    ";2:s="SYNTH   ";default:s="SYNTH   ";
                endcase
            end else if(row==13)begin
                case(opt)
                 0:s="MINUS   ";3:s="PLUS    ";default:s="        ";
                endcase
            end else begin
                case (opt)
                    2'd0: s = "SINE    ";
                    2'd1: s = "SQUARE  ";
                    2'd2: s = "TRIANGLE";
                    default: s = "SAW     ";
                endcase
            end
            sel_option_char = (col < 6'd8) ? s[63 - col*8 -: 8] : 7'd32;
        end
    endfunction

    reg [1:0] sel_draw_opt;
    always @(*) begin
        if (lx_2 < 11'd660)
            sel_draw_opt = 2'd0;
        else if (lx_2 < 11'd1000)
            sel_draw_opt = 2'd1;
        else if (lx_2 < 11'd1340)
            sel_draw_opt = 2'd2;
        else
            sel_draw_opt = 2'd3;
    end

    reg [10:0] sel_text_origin;
    always @(*) begin
        case (sel_draw_opt)
            2'd0: sel_text_origin = 11'd426;
            2'd1: sel_text_origin = 11'd766;
            2'd2: sel_text_origin = 11'd1106;
            default: sel_text_origin = 11'd1446;
        endcase
    end
    wire [10:0] sel_text_x = lx_2 - sel_text_origin;
    wire [5:0]  sel_text_col = sel_text_x[10:4];
    wire        in_sel_text = sel_row && (lx_2 >= sel_text_origin) &&
                              (lx_2 < (sel_text_origin + 11'd128)) &&
                              (lyo >= 10'd10) && (lyo < 10'd42);
    wire [2:0] octave_magnitude = p_octave[2] ? (~p_octave + 3'd1) : p_octave;
    wire [6:0] sel_text_char = (row_r==13 && sel_draw_opt==1) ?
      (sel_text_col==0?(p_octave[2]?7'd45:7'd43):sel_text_col==1?(7'd48+{4'd0,octave_magnitude}):7'd32):sel_option_char(row_r,sel_text_col,sel_draw_opt);

    // Two fixed top-level page buttons.  They sit above the scrolled settings
    // canvas, do not consume scroll_y, and are always visible on both pages.
    wire in_settings_button = (lx_2 >= 11'd1744) && (lx_2 < 11'd1888) &&
                              (ly_2 >= 10'd16) && (ly_2 < 10'd112);
    wire in_home_button     = (lx_2 >= 11'd1744) && (lx_2 < 11'd1888) &&
                              (ly_2 >= 10'd128) && (ly_2 < 10'd224);
    wire settings_button_border = in_settings_button &&
                                  ((lx_2 < 11'd1748) || (lx_2 >= 11'd1884) ||
                                   (ly_2 < 10'd20) || (ly_2 >= 10'd108));
    wire home_button_border = in_home_button &&
                              ((lx_2 < 11'd1748) || (lx_2 >= 11'd1884) ||
                               (ly_2 < 10'd132) || (ly_2 >= 10'd220));
    wire in_theremin_button = (lx_2 >= 11'd1744) && (lx_2 < 11'd1888) &&
                               (ly_2 >= 10'd240) && (ly_2 < 10'd336);
    wire theremin_button_border = in_theremin_button &&
                                  ((lx_2 < 11'd1748) || (lx_2 >= 11'd1884) ||
                                   (ly_2 < 10'd244) || (ly_2 >= 10'd332));
    wire page_button_border = settings_button_border || home_button_border || theremin_button_border;
    wire page_button_fill = (in_settings_button && !settings_button_border) ||
                            (in_home_button && !home_button_border) ||
                            (in_theremin_button && !theremin_button_border);

    wire in_settings_text = in_settings_button &&
                            (ly_2 >= 10'd48) && (ly_2 < 10'd80) &&
                            (lx_2 >= 11'd1752) && (lx_2 < 11'd1880);
    wire in_home_text = in_home_button &&
                        (ly_2 >= 10'd160) && (ly_2 < 10'd192) &&
                        (lx_2 >= 11'd1784) && (lx_2 < 11'd1848);
    wire in_theremin_nav_text = in_theremin_button &&
                                (ly_2 >= 10'd272) && (ly_2 < 10'd304) &&
                                (lx_2 >= 11'd1752) && (lx_2 < 11'd1880);
    wire in_page_text = in_settings_text || in_home_text || in_theremin_nav_text;
    wire [10:0] page_text_x = lx_2 - (in_home_text ? 11'd1784 : 11'd1752);
    wire [9:0]  page_text_y = in_home_text ? (ly_2 - 10'd160) :
                              in_theremin_nav_text ? (ly_2 - 10'd272) : (ly_2 - 10'd48);
    wire [3:0]  page_text_col = page_text_x[6:4];
    wire [3:0]  page_text_row = page_text_y[4:1];
    wire [6:0]  settings_text_char = page_button_char(1'b1, page_text_col);
    wire [6:0]  home_text_char = page_button_char(1'b0, page_text_col);
    function [6:0] theremin_nav_char;
        input [3:0] col;
        reg [63:0] word_text;
        begin
            word_text="THEREMIN";
            theremin_nav_char=word_text[63-col*8 -: 8];
        end
    endfunction
    wire [6:0] page_text_char = in_theremin_nav_text ? theremin_nav_char(page_text_col) :
                               in_home_text ? home_text_char : settings_text_char;

    // The small independent panel reuses the existing glyph pipeline. Fixed
    // button coordinates and +/-5 actions require no new sliders or dividers.
    wire th_power_row = (ly_2 >= 10'd104) && (ly_2 < 10'd168);
    wire th_mix_row = (ly_2 >= 10'd216) && (ly_2 < 10'd280);
    wire th_rate_row = (ly_2 >= 10'd336) && (ly_2 < 10'd400);
    wire th_left_box = (lx_2 >= 11'd320) && (lx_2 < 11'd660);
    wire th_on_box = (lx_2 >= 11'd680) && (lx_2 < 11'd1020);
    wire th_plus_box = (lx_2 >= 11'd1020) && (lx_2 < 11'd1360);
    wire th_rate_box = (lx_2 >= 11'd320) && (lx_2 < 11'd1020);
    wire th_box = theremin_2 && ((th_power_row && (th_left_box || th_on_box)) ||
                    (th_mix_row && (th_left_box || th_plus_box)) || (th_rate_row && th_rate_box));
    wire th_x_border = ((th_power_row || th_mix_row) && th_left_box && ((lx_2 < 11'd324) || (lx_2 >= 11'd656))) ||
                        (th_power_row && th_on_box && ((lx_2 < 11'd684) || (lx_2 >= 11'd1016))) ||
                        (th_mix_row && th_plus_box && ((lx_2 < 11'd1024) || (lx_2 >= 11'd1356))) ||
                        (th_rate_row && th_rate_box && ((lx_2 < 11'd324) || (lx_2 >= 11'd1016)));
    wire th_y_border = (th_power_row && ((ly_2 < 10'd108) || (ly_2 >= 10'd164))) ||
                        (th_mix_row && ((ly_2 < 10'd220) || (ly_2 >= 10'd276))) ||
                        (th_rate_row && ((ly_2 < 10'd340) || (ly_2 >= 10'd396)));
    wire th_border = th_box && (th_x_border || th_y_border);
    reg [3:0] th_text_kind;
    reg [10:0] th_text_origin;
    reg [9:0] th_text_top;
    reg th_text_area;
    always @* begin
        th_text_kind=0;th_text_origin=11'd64;th_text_top=10'd32;th_text_area=0;
        if (ly_2 >= 10'd32 && ly_2 < 10'd64) begin
            th_text_kind=0;th_text_area=(lx_2 >= 11'd64 && lx_2 < 11'd320);
        end else if (ly_2 >= 10'd120 && ly_2 < 10'd152) begin
            th_text_top=10'd120;
            case (1'b1)
                (lx_2 >= 11'd64 && lx_2 < 11'd144): begin th_text_kind=1;th_text_area=1;end
                (lx_2 >= 11'd464 && lx_2 < 11'd512): begin th_text_kind=2;th_text_origin=464;th_text_area=1;end
                (lx_2 >= 11'd832 && lx_2 < 11'd864): begin th_text_kind=3;th_text_origin=832;th_text_area=1;end
                default: ;
            endcase
        end else if (ly_2 >= 10'd232 && ly_2 < 10'd264) begin
            th_text_top=10'd232;
            case (1'b1)
                (lx_2 >= 11'd64 && lx_2 < 11'd112): begin th_text_kind=4;th_text_area=1;end
                (lx_2 >= 11'd440 && lx_2 < 11'd536): begin th_text_kind=5;th_text_origin=440;th_text_area=1;end
                (lx_2 >= 11'd784 && lx_2 < 11'd848): begin th_text_kind=6;th_text_origin=784;th_text_area=1;end
                (lx_2 >= 11'd1152 && lx_2 < 11'd1232): begin th_text_kind=7;th_text_origin=1152;th_text_area=1;end
                default: ;
            endcase
        end else if (ly_2 >= 10'd352 && ly_2 < 10'd384) begin
            th_text_top=10'd352;
            case (1'b1)
                (lx_2 >= 11'd64 && lx_2 < 11'd128): begin th_text_kind=8;th_text_area=1;end
                (lx_2 >= 11'd608 && lx_2 < 11'd720): begin th_text_kind=9;th_text_origin=608;th_text_area=1;end
                default: ;
            endcase
        end
    end
    reg [3:0] th_mix_tens,th_mix_ones;
    always @(posedge pixel_clock) begin
        if(reset)begin th_mix_tens<=2;th_mix_ones<=5;end
        else begin
            th_mix_tens<=percent_tens({1'b0,p_theremin_mix});
            th_mix_ones<=percent_ones({1'b0,p_theremin_mix});
        end
    end
    function [6:0] theremin_panel_char;
        input [3:0] kind;
        input [3:0] col;
        input enabled;
        input [6:0] mix;
        input [3:0] tens,ones;
        reg [127:0] word_text;
        begin
            case(kind)
                0: word_text=enabled ? "THEREMIN ON     " : "THEREMIN OFF    ";
                1: word_text="POWER           ";
                2: word_text="OFF             ";
                3: word_text="ON              ";
                4: word_text="MIX             ";
                5: word_text="MINUS5          ";
                7: word_text="PLUS5           ";
                8: word_text="RATE            ";
                9: word_text="SET90HZ         ";
                default: word_text="                ";
            endcase
            if(kind==6)begin
                case(col)
                    0:theremin_panel_char=(mix==100)?7'd49:7'd32;
                    1:theremin_panel_char=7'd48+((mix==100)?4'd0:tens);
                    2:theremin_panel_char=7'd48+((mix==100)?4'd0:ones);
                    3:theremin_panel_char=7'd37;
                    default:theremin_panel_char=7'd32;
                endcase
            end else theremin_panel_char=word_text[127-col*8 -: 8];
        end
    endfunction
    wire [10:0] th_text_x=lx_2-th_text_origin;
    wire [9:0] th_text_y=ly_2-th_text_top;
    wire th_text=theremin_2 && th_text_area;
    wire [6:0] th_text_char=theremin_panel_char(th_text_kind,th_text_x[7:4],
                                    p_theremin_enable,p_theremin_mix,th_mix_tens,th_mix_ones);

    wire [6:0] tchar = th_text ? th_text_char : in_page_text ? page_text_char :
                       (page_2 && in_label) ? label_char(row_r, lcol) :
                       (page_2 && in_value) ? slider_char :
                       (page_2 && in_sel_text) ? sel_text_char : 7'd32;
    wire [2:0] text_tgx = th_text ? th_text_x[3:1] : in_page_text ? page_text_x[3:1] :
                          (page_2 && in_sel_text) ? sel_text_x[3:1] : tgx;
    wire [3:0] text_tgy = th_text ? th_text_y[4:1] : in_page_text ? page_text_row : tgy;

    // ---- MAIN spectrum: 64 unique bars, 22 px wide, 26 px pitch.
    // Bands alternate outwards from the centre: band 0 centre-left, band 1
    // centre-right, band 2 one step further left, etc.  No band is duplicated.
    wire [6:0] bar_slot = bar_slot_q;
    wire [5:0] bar_freq = bar_freq_q;

    // Request the synchronous spectrum RAM one pipeline stage ahead.  After
    // the next pixel_clock edge rd_data corresponds to lx_2, because lx_2 is
    // loaded from the previous lx_r on that same edge.
    wire [10:0] bar_req_x = lx_r - 11'd32;
    wire [21:0] bar_req_x22 = {11'd0, bar_req_x};
    wire [21:0] bar_req_mul = (bar_req_x22 << 11) + (bar_req_x22 << 8) +
                              (bar_req_x22 << 7) + (bar_req_x22 << 6) +
                              (bar_req_x22 << 4) + (bar_req_x22 << 3) +
                               bar_req_x22;
    wire [5:0] bar_req_raw = bar_req_mul[21:16];
    assign bar_req_slot = {1'b0, bar_req_raw};
    assign bar_req_freq = bar_req_raw[5] ?
                           ({bar_req_raw[4:0], 1'b0} + 6'd1) :
                           (6'd62 - {bar_req_raw[4:0], 1'b0});
    assign spec_addr = bar_req_freq;

    wire [10:0] bar_slot11 = {4'd0, bar_slot};
    wire [10:0] bar_start = 11'd32 + (bar_slot11 << 4) +
                            (bar_slot11 << 3) + (bar_slot11 << 1);
    wire [10:0] bar_inside = lx_2 - bar_start;
    wire [9:0]  bar_level = spec_level;
    wire [27:0] bar_level28 = {18'd0, bar_level};
    wire [27:0] bar_height_w = (bar_level28 << 8) + (bar_level28 << 7) +
                               (bar_level28 << 4);   // level * 400
    wire [8:0]  bar_height = bar_height_w[18:10];
    wire [9:0]  bar_top = 10'd424 - {1'b0, bar_height};
    wire bar_area = !page_2 && !theremin_2 && (lx_2 >= 11'd32) && (lx_2 < 11'd1693) &&
                    (bar_inside < 11'd22) && (bar_height != 9'd0) &&
                    (ly_2 >= bar_top) && (ly_2 <= 10'd424);
    wire bar_peak = bar_area && ((ly_2 == bar_top) ||
                                 (ly_2 == (bar_top + 10'd1)) ||
                                 (ly_2 == (bar_top + 10'd2)));
    wire bar_glow = bar_area && (ly_2 < (bar_top + 10'd11));

    reg [23:0] bar_base_color;
    reg [23:0] bar_glow_color;
    reg [23:0] bar_peak_color;
    always @(*) begin
        // Four amplitude zones.  The whole column changes hue as its current
        // level rises; this costs only a 2-bit decode and constant muxes.
        case (bar_level[9:8])
            2'd0: begin
                bar_base_color = 24'h1C4FA0;
                bar_glow_color = 24'h3880D0;
                bar_peak_color = 24'h80C8FF;
            end
            2'd1: begin
                bar_base_color = 24'h18A89C;
                bar_glow_color = 24'h50F0E0;
                bar_peak_color = 24'hB8FFF8;
            end
            2'd2: begin
                bar_base_color = 24'h7040C8;
                bar_glow_color = 24'hA070F0;
                bar_peak_color = 24'hE0C8FF;
            end
            default: begin
                bar_base_color = 24'hD05060;
                bar_glow_color = 24'hFF8850;
                bar_peak_color = 24'hFFF0B0;
            end
        endcase
    end

    // Sparse grid and a centre beam make the mirrored frequency direction
    // readable without a framebuffer or alpha blender.
    wire main_grid = !page_2 && !theremin_2 && (lx_2 >= 11'd32) && (lx_2 < 11'd1693) &&
                     ((ly_2 == 10'd104) || (ly_2 == 10'd184) ||
                      (ly_2 == 10'd264) || (ly_2 == 10'd344) ||
                      (ly_2 == 10'd424));
    wire main_center = !page_2 && !theremin_2 && (lx_2 >= 11'd860) && (lx_2 < 11'd864) &&
                       (ly_2 >= 10'd24) && (ly_2 <= 10'd424);

    // ----  ------------------------------------------------------
    wire in_track = (lx_2 >= 11'd320) && (lx_2 < 11'd1520) &&
                    (lyo >= 10'd22) && (lyo < 10'd30);
    wire track_fill = (lx_2 < knob_pos);
    // Reachable knob_pos is 320..1518 (slider cache) or zero for
    // invalid rows 14/15. Unsigned distance replaces the two-sided compare;
    // the zero guard preserves invalid-row blanking, including lx=0..9.
    wire [10:0] knob_delta = (lx_2 + 11'd10) - knob_pos;
    wire in_knob = (|knob_pos) && (knob_delta < 11'd20) &&
                   (lyo >= 10'd16) && (lyo < 10'd36);

    wire in_sel_box = (lx_2 >= 11'd320) && (lx_2 < 11'd1680) &&
                      (lyo >= 10'd8) && (lyo < 10'd44);
    wire sel_border = in_sel_box && ((lx_2 < 11'd324) || (lx_2 >= 11'd1676) ||
                                     (lyo < 10'd12) || (lyo >= 10'd40));
    wire sel_separator = in_sel_box &&
                         ((row_r == 4'd12) ?
                          ((lx_2 >= 11'd996) && (lx_2 < 11'd1004)) :
                          (((lx_2 >= 11'd656) && (lx_2 < 11'd664)) ||
                           ((lx_2 >= 11'd996) && (lx_2 < 11'd1004)) ||
                           ((lx_2 >= 11'd1336) && (lx_2 < 11'd1344))));
    wire sel_selected = sel_row && in_sel_box && (sel_draw_opt == sel_cur);

    // Moved out of the old top-right block so it cannot overlap the fixed
    // page button.  A 16x16 solid dot sits immediately left of the button.
    wire status_dot = (lx_2 >= 11'd1704) && (lx_2 < 11'd1720) &&
                      (ly_2 >= 10'd48) && (ly_2 < 10'd64);

    //  lx 1888..1900 264
    wire in_sb      = (lx_2 >= 11'd1888) && (lx_2 < 11'd1900) &&
                      (ly_2 >= 10'd8) && (ly_2 < 10'd432);
    wire in_sb_thumb = in_sb && (ly_2 >= (10'd8 + thumb_r)) &&
                       (ly_2 < (10'd8 + thumb_r + 10'd264));

    reg [23:0] state_color;
    always @(*) begin
        case (t_state2)
            3'd0:    state_color = 24'h401040;
            3'd1:    state_color = 24'h605000;
            3'd2:    state_color = 24'h004850;
            3'd3:    state_color = 24'h601010;
            default: state_color = 24'h103020;
        endcase
    end
    wire [23:0] status_color = playing ? 24'h20C060 :
                               (mode_slider ? 24'h2080FF : state_color);

    wire [11:0] dx = (lx_2 > t_lx2) ? (lx_2 - t_lx2) : (t_lx2 - lx_2);
    wire [11:0] dy = (ly_2 > t_ly2) ? (ly_2 - t_ly2) : (t_ly2 - ly_2);
    wire        touch_cross = t_d2 && ((dx <= 12'd4) || (dy <= 12'd4));

    // ----  +  ------------------------------
    reg  [6:0] tchar3;
    reg  [2:0] tgx3;
    reg  [3:0] tgy3;
    reg        lab3, val3, selrow3, selbord3, selbox3;
    reg        selselected3;
    reg        knob3, track3, fill3, sbt3, sb3, dot3, cross3;
    reg        bar3, bar_peak3, bar_glow3, grid3, center3;
    reg [23:0] bar_base3, bar_glow_color3, bar_peak_color3;
    reg        btn_border3, btn_fill3, btn_text3;
    reg        den_4, hs_4, vs_4, ls_4;

    always @(posedge pixel_clock) begin
        if (reset) begin
            tchar3 <= 7'd32; tgx3 <= 3'd0; tgy3 <= 4'd0;
            lab3 <= 1'b0; val3 <= 1'b0; selrow3 <= 1'b0; selbord3 <= 1'b0; selbox3 <= 1'b0;
            selselected3 <= 1'b0;
            knob3 <= 1'b0; track3 <= 1'b0; fill3 <= 1'b0;
            sbt3 <= 1'b0; sb3 <= 1'b0; dot3 <= 1'b0; cross3 <= 1'b0;
            bar3 <= 1'b0; bar_peak3 <= 1'b0; bar_glow3 <= 1'b0;
            grid3 <= 1'b0; center3 <= 1'b0;
            bar_base3 <= 24'h000000;
            bar_glow_color3 <= 24'h000000;
            bar_peak_color3 <= 24'h000000;
            btn_border3 <= 1'b0; btn_fill3 <= 1'b0; btn_text3 <= 1'b0;
            den_4 <= 1'b0; hs_4 <= 1'b0; vs_4 <= 1'b0; ls_4 <= 1'b0;
        end else begin
            tchar3   <= tchar;
            tgx3     <= text_tgx;
            tgy3     <= text_tgy;
            lab3     <= page_2 && (in_label || in_sel_text);
            val3     <= page_2 && in_value;
            selrow3  <= page_2 && sel_row;
            selbord3 <= page_2 && sel_row && (sel_border || sel_separator);
            selbox3  <= page_2 && sel_row && in_sel_box;
            knob3    <= page_2 && in_knob;
            track3   <= page_2 && in_track;
            fill3    <= page_2 && track_fill;
            sbt3     <= page_2 && in_sb_thumb;
            sb3      <= page_2 && in_sb;
            dot3     <= status_dot;
            cross3   <= touch_cross;
            bar3     <= bar_area;
            bar_peak3 <= bar_peak;
            bar_glow3 <= bar_glow;
            grid3 <= main_grid;
            center3 <= main_center;
            bar_base3 <= bar_base_color;
            bar_glow_color3 <= bar_glow_color;
            bar_peak_color3 <= bar_peak_color;
            selselected3 <= page_2 && sel_selected;
            btn_border3 <= page_button_border || th_border;
            btn_fill3   <= page_button_fill || (th_box && !th_border);
            btn_text3   <= in_page_text || th_text;
            den_4 <= den_3; hs_4 <= hs_3; vs_4 <= vs_3; ls_4 <= ls_3;
        end
    end

    // ----  +  --------------------------------------
    wire [7:0] tbits;
    ui_font u_font (.ch(tchar3), .row(tgy3), .bits(tbits));
    wire tbit4 = (lab3 || val3 || btn_text3) && tbits[3'd7 - tgx3];

    reg [23:0] color;
    always @(*) begin
        color = 24'h080C14;
        if (btn_border3)
            color = 24'h6090C8;
        else if (btn_text3 && tbit4)
            color = 24'hFFFFFF;
        else if (dot3)
            color = status_color;
        else if (btn_fill3) begin
            if (cross3) color = 24'hFFFFFF;
            else        color = 24'h101A26;
        end
        else if (selbord3)
            color = 24'h4080C0;
        else if (tbit4)
            color = 24'hFFFFFF;
        else if (selbox3)
            color = selselected3 ? 24'h205C98 : 24'h101A26;
        else if (knob3)
            color = 24'hFFC000;
        else if (track3)
            color = fill3 ? 24'h2060C0 : 24'h202830;
        else if (sbt3)
            color = 24'h8090A0;
        else if (sb3)
            color = 24'h1A2230;
        else if (bar3) begin
            if (cross3)      color = 24'hFFFFFF;
            else if (bar_peak3) color = bar_peak_color3;
            else if (bar_glow3) color = bar_glow_color3;
            else                color = bar_base3;
        end
        else if (cross3)
            color = 24'hFFFFFF;
        else if (center3)
            color = 24'h205060;
        else if (grid3)
            color = 24'h142434;
    end

    reg [23:0] color_r;
    always @(posedge pixel_clock) begin
        if (reset) color_r <= 24'h000000;
        else       color_r <= color;
    end

    // 11 ??????????????????
    assign p_adsr_a  = sval[0][9:5];
    assign p_adsr_d  = sval[1][9:5];
    assign p_adsr_s  = sval[2][9:5];
    assign p_adsr_r  = sval[3][9:5];
    assign p_eq      = selv[4];
    assign p_reverb  = selv[5];
    assign p_timbre  = selv[11];
    assign p_instrument=selv[12];
    assign p_pan     = sval[6][9:5];
    assign p_dry     = {sval[7],  8'd0};
    assign p_wet     = {sval[8],  8'd0};
    assign p_width   = {sval[9],  8'd0};
    assign p_master  = {sval[10], 8'd0};

    assign video_pixel      = color_r;
    assign video_den        = den_4;
    assign video_hsync      = hs_4;
    assign video_vsync      = vs_4;
    assign video_line_start = ls_4;

endmodule
`default_nettype wire
