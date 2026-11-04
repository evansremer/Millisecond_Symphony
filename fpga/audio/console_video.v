// Fixed geometry + tiny character banks. Native 440x1920 timing is unchanged.
// Every status/config bundle is latched by apb_console at VSYNC.
module console_video(
 input pixel_clock,reset,ready,input [511:0] state,
 output frame_tick,output [11:0] tile_address,input [7:0] tile_data,
 input [9:0] spec_level,output [5:0] spec_addr,
 input [23:0] raw_level,output [8:0] raw_addr,
 input xy_pixel,output [13:0] xy_address,
 output [23:0] video_pixel,output video_den,video_hsync,video_vsync,video_line_start
);
 wire [13:0] px,py,hpos;wire den,hs,vs,ls;
 video_timing_ctrl #(.VIDEO_H_LENGTH(540),.VIDEO_V_LENGTH(2209),.VIDEO_HSYNC_POL(1),.VIDEO_HSYNC_LEN(20),.VIDEO_HBP_LEN(40),.VIDEO_H_VISIBLE(440),.VIDEO_VSYNC_POL(1),.VIDEO_VSYNC_LEN(4),.VIDEO_VBP_LEN(12),.VIDEO_V_VISIBLE(1920)) timing(
  .pixel_clock(pixel_clock),.reset(reset),.timing_h_pos(hpos),.timing_v_pos(),.pixel_x(px),.pixel_y(py),.video_vsync(vs),.video_hsync(hs),.video_den(den),.video_line_start(ls));
 reg vs_d;always @(posedge pixel_clock)if(reset)vs_d<=0;else vs_d<=vs;
 assign frame_tick=vs && !vs_d;
 // Native vertical position changes only during horizontal blanking.
 // Register its rotated X transform before the hit-test priority network.
 wire [10:0] rotated_x=11'd1919-py[10:0];
 reg [10:0] x;always @(posedge pixel_clock)x<=rotated_x;
 wire [8:0] y=hpos[8:0]-9'd60;
 // Expanded 512x160 normalized rectangular viewport. Same 128x128 banks:
 // X repeats 4 pixels, Y repeats 5/4 pixels. Deliberately unequal screen scales,
 // not a calibrated equal-axis oscilloscope. No pixel-rate multiply/divide.
 wire [10:0] xy_dx=x-11'd592;
 wire [6:0] xy_x=xy_dx[8:2];
 reg [6:0] xy_y;reg [2:0] xy_repeat;
 always @(posedge pixel_clock)begin
  if(reset || hpos==14'd171)begin xy_y<=0;xy_repeat<=0;end
  else if(hpos>=14'd172 && hpos<14'd331)begin
   if(xy_repeat!=0)xy_y<=xy_y+1'b1;
   xy_repeat<=xy_repeat==4?0:xy_repeat+1'b1;
  end
 end
 assign xy_address={xy_y,xy_x};
 // Reference radial palette, Chebyshev distance; small logic before stage1.
 wire [6:0] xy_abs_x=xy_x[6]?xy_x-7'd64:7'd64-xy_x;
 wire [6:0] xy_abs_y=xy_y[6]?xy_y-7'd64:7'd64-xy_y;
 wire [6:0] xy_radius=xy_abs_x>xy_abs_y?xy_abs_x:xy_abs_y;
 wire [5:0] xy_r=xy_radius[6]?6'd63:xy_radius[5:0];
 wire [4:0] xy_g=xy_r[5]?~xy_r[4:0]:xy_r[4:0];
 wire [23:0] xy_color={xy_r,2'b0,xy_g,3'b0,~{xy_r,2'b0}};
 assign tile_address=y<416?((y>>5)*12'd120)+(x>>4):12'd2047;
 // Spectrum addresses are registered with the same geometric pipeline as RAM.
 wire [2:0] zoom=state[251:249];
 wire [1:0] page=state[1:0],subpage=state[3:2];wire stopped=state[4];
 wire [10:0] cursor_x=state[158:148];
 reg [8:0] full_index;reg [5:0] spectrum_index;reg [4:0] spectrum_column;
 reg [4:0] divide_count;reg [19:0] raw_n,spec_n,raw_q,spec_q;
 reg [10:0] raw_rem;reg [4:0] spec_rem;
 wire [11:0] raw_trial={raw_rem,raw_n[19]};wire [5:0] spec_trial={spec_rem,spec_n[19]};
 wire raw_ge=raw_trial>=1064;wire [4:0] spec_divisor=page==0?5'd11:5'd22;
 wire spec_ge=spec_trial>=spec_divisor;
 wire [19:0] raw_next={raw_q[18:0],raw_ge},spec_next={spec_q[18:0],spec_ge};
 // Both divisions finish in blanking, before native H=60. No pixel-rate DSP.
 always @(posedge pixel_clock)begin
  if(reset)begin divide_count<=0;full_index<=0;spectrum_index<=0;spectrum_column<=0;raw_n<=0;spec_n<=0;raw_q<=0;spec_q<=0;raw_rem<=0;spec_rem<=0;end
  else if(ls)begin
   raw_n<=rotated_x>=120 && rotated_x<1184?{(rotated_x-11'd120),9'd0}:20'd0;
   spec_n<=page==0?(rotated_x>=1368 && rotated_x<1720?(rotated_x-1368)*2:20'd0):(rotated_x>=320 && rotated_x<1720?rotated_x-320:20'd0);
   raw_q<=0;spec_q<=0;raw_rem<=0;spec_rem<=0;divide_count<=20;
  end else if(divide_count!=0)begin
   raw_n<=raw_n<<1;spec_n<=spec_n<<1;raw_q<=raw_next;spec_q<=spec_next;
   raw_rem<=raw_ge?raw_trial-1064:raw_trial;spec_rem<=spec_ge?spec_trial-spec_divisor:spec_trial;
   divide_count<=divide_count-1'b1;
   if(divide_count==1)begin full_index<=raw_next[8:0];spectrum_index<=spec_next[5:0];spectrum_column<=spec_ge?spec_trial-spec_divisor:spec_trial;end
  end
 end
 assign spec_addr=spectrum_index;
 assign raw_addr=full_index>>zoom;
 // Exact constant divisions run during H blanking, never in the pixel color
 // priority chain. Twenty cycles complete before active native H=60.
 reg [4:0] loop_div_count;
 reg [19:0] loop_num,loop_q,vol_num,vol_q,click_num,click_q,od_num,od_q;
 reg [8:0] loop_rem,vol_rem,click_rem,od_rem;
 reg [10:0] loop_width,vol_width,click_width,od_width;
 wire [9:0] od_trial={od_rem,od_num[19]};wire od_ge=od_trial>=100;
 wire [9:0] loop_trial={loop_rem,loop_num[19]},vol_trial={vol_rem,vol_num[19]},click_trial={click_rem,click_num[19]};
 wire loop_ge=loop_trial>=255,vol_ge=vol_trial>=100,click_ge=click_trial>=100;
 always @(posedge pixel_clock)begin
  if(reset)begin
   loop_div_count<=0;loop_num<=0;loop_q<=0;vol_num<=0;vol_q<=0;click_num<=0;click_q<=0;
   loop_rem<=0;vol_rem<=0;click_rem<=0;loop_width<=0;vol_width<=0;click_width<=0;od_num<=0;od_q<=0;od_rem<=0;od_width<=0;
  end else if(ls)begin
   loop_num<=state[23:16]*11'd1344;vol_num<=state[183:177]*8'd152;click_num<=state[191:184]*10'd568;
   od_num<=state[39:33]*10'd568;od_q<=0;od_rem<=0;
   loop_q<=0;vol_q<=0;click_q<=0;loop_rem<=0;vol_rem<=0;click_rem<=0;loop_div_count<=20;
  end else if(loop_div_count!=0)begin
   loop_num<=loop_num<<1;vol_num<=vol_num<<1;click_num<=click_num<<1;
   od_num<=od_num<<1;od_q<={od_q[18:0],od_ge};od_rem<=od_ge?od_trial-100:od_trial;
   loop_q<={loop_q[18:0],loop_ge};vol_q<={vol_q[18:0],vol_ge};click_q<={click_q[18:0],click_ge};
   loop_rem<=loop_ge?loop_trial-255:loop_trial;vol_rem<=vol_ge?vol_trial-100:vol_trial;click_rem<=click_ge?click_trial-100:click_trial;
   loop_div_count<=loop_div_count-1'b1;
   if(loop_div_count==1)begin
    loop_width<={loop_q[9:0],loop_ge};vol_width<={vol_q[9:0],vol_ge};click_width<={click_q[9:0],click_ge};
    od_width<={od_q[9:0],od_ge};
   end
  end
 end
 localparam BG=24'h0b101a,PANEL=24'h151e2d,BUTTON=24'h243247,SELECTED=24'h294758,
  CYAN=24'h5cdeed,ORANGE=24'hffb562,PURPLE=24'hc1a0ff,RED=24'hff8594,WHITE=24'hedf3fc;
 wire [115:0] cfg=state[371:256];
 wire [1:0] instrument=cfg[107:106],reverb=cfg[80:79],waveform=cfg[78:77];
 wire [10:0] master_x=state[490:480];
 wire [10:0] pitch_x=state[501:491];
 reg [10:0] volume_x_q;
 always @(posedge pixel_clock)if(ls)volume_x_q<=11'd1260+{1'b0,state[511:502]};
 reg [23:0] geometry;reg [23:0] accent;integer i;reg [4:0] level;
 function hit;input [10:0] hx;input [8:0] hy;input integer l,t,r,b;begin hit=hx>=l && hx<r && hy>=t && hy<b;end endfunction
 function [23:0] button_color;input chosen;begin button_color=chosen?SELECTED:BUTTON;end endfunction
 // Independent scan-drawing layers. Stage 1 captures each small layer;
 // stage 2 preserves original coverage order, without a framebuffer.
 reg [23:0] layer0,layer0_q;reg valid0,valid0_q;integer i0;reg [4:0] level0;
 always @*begin
 layer0=BG;valid0=1;level0=0;
  if(hit(x,y,8,8,1720,80))begin layer0=PANEL;valid0=1;end
  if(hit(x,y,1064,8,1144,80)||hit(x,y,1512,8,1592,80)||hit(x,y,1600,8,1720,80))begin layer0=BUTTON;valid0=1;end
  if(hit(x,y,1170,53,master_x,64))begin layer0=CYAN;valid0=1;end
  if(hit(x,y,840,44,840+state[431:416],51)||hit(x,y,840,62,840+state[447:432],69))begin layer0=24'h8ce2b3;valid0=1;end
  for(i0=0;i0<4;i0=i0+1)if(hit(x,y,1728,8+i0*80,1912,80+i0*80))begin begin layer0=button_color(page==i0);valid0=1;end if(page==i0 && (x<1732 || x>=1908 || y<12+i0*80 || y>=76+i0*80))begin layer0=CYAN;valid0=1;end end
  if(hit(x,y,1728,340,1912,432))begin layer0=stopped?24'h345646:24'h492535;valid0=1;end
 end
 always @(posedge pixel_clock)begin layer0_q<=layer0;valid0_q<=valid0;end
 reg [23:0] layer1,layer1_q;reg valid1,valid1_q;integer i1;reg [4:0] level1;
 always @*begin
 layer1=BG;valid1=0;level1=0;
  if(page==0)begin
   if(hit(x,y,8,88,560,272)||hit(x,y,568,88,1128,272)||hit(x,y,1136,88,1720,272)||hit(x,y,8,280,1360,432)||hit(x,y,1368,280,1720,432))begin layer1=PANEL;valid1=1;end
   for(i1=0;i1<3;i1=i1+1)if(hit(x,y,20+i1*176,112,188+i1*176,184))begin layer1=button_color(instrument==i1);valid1=1;end
   if(hit(x,y,20,200,100,272)||hit(x,y,108,200,204,272)||hit(x,y,212,200,292,272))begin layer1=BUTTON;valid1=1;end
  end
 end
 always @(posedge pixel_clock)begin layer1_q<=layer1;valid1_q<=valid1;end
 // Drum feedback is a separate short registered layer, not an extension of
 // the already tight header layer0 or keyboard layer1 critical paths.
 reg [23:0] drum_layer,drum_layer_q;reg drum_valid,drum_valid_q;
 integer drum_i;reg [4:0] drum_level;
 always @*begin
  drum_layer=BUTTON;drum_valid=0;drum_level=0;
  if(page==0)for(drum_i=0;drum_i<10;drum_i=drum_i+1)begin
   if(drum_i<6)drum_level=(state[223:192]>>(drum_i*5))&31;
   else drum_level=(state[255:224]>>((drum_i-6)*5))&31;
   if(hit(x,y,4+(drum_i%5)*112,(drum_i/5)*36,108+(drum_i%5)*112,32+(drum_i/5)*36))begin
    drum_layer=drum_level!=0?24'h61432b:BUTTON;drum_valid=1;
   end
  end
 end
 always @(posedge pixel_clock)begin drum_layer_q<=drum_layer;drum_valid_q<=drum_valid;end
 reg [23:0] layer2,layer2_q;reg valid2,valid2_q;integer i2;reg [4:0] level2;
 always @*begin
 layer2=BG;valid2=0;level2=0;
  if(page==0)begin
   if(hit(x,y,1148,112,1244,184))begin layer2=button_color(state[32]);valid2=1;end
   if(hit(x,y,1148,200,1228,272)||hit(x,y,1628,200,1708,272))begin layer2=BUTTON;valid2=1;end
   if(hit(x,y,1160,194,1696,199))begin layer2=24'h344660;valid2=1;end
   for(i2=0;i2<25;i2=i2+1)
    if(x==1160+(i2*535)/24 && y>=188 && y<204)begin layer2=24'h9caec7;valid2=1;end
   if(y>=184 && y<204 && x>=pitch_x && x<pitch_x+5)begin layer2=state[99:96]==5?PURPLE:24'h788398;valid2=1;end
   if(x>=1260 && x<volume_x_q && y>=169 && y<174)begin layer2=PURPLE;valid2=1;end

  end
 end
 always @(posedge pixel_clock)begin layer2_q<=layer2;valid2_q<=valid2;end
 reg [23:0] layer3,layer3_q;reg valid3,valid3_q;integer i3;reg [4:0] level3;
 always @*begin
 layer3=BG;valid3=0;level3=0;
  if(page==0)begin
   // Transport states come from FPGA-confirmed telemetry in the frame bundle.
   if(hit(x,y,8,280,88,352)||hit(x,y,208,280,288,352)||hit(x,y,296,280,400,352)||hit(x,y,976,280,1080,352))begin layer3=BUTTON;valid3=1;end
   for(i3=0;i3<4;i3=i3+1)if(hit(x,y,408+i3*112,280,512+i3*112,352))begin layer3=button_color(state[124:121]==(1<<i3));valid3=1;end
   if(hit(x,y,856,280,968,352))begin layer3=button_color(state[116]);valid3=1;end
   if(hit(x,y,8,360,176,432))begin layer3=button_color(state[107:104]>=1 && state[107:104]<=3);valid3=1;end
   if(hit(x,y,184,360,352,432))begin layer3=button_color(state[107:104]==4 || state[112]);valid3=1;end
   if(hit(x,y,360,360,528,432))begin layer3=button_color(state[110]||state[109]);valid3=1;end
   if(hit(x,y,536,360,704,432))begin layer3=button_color(state[111]);valid3=1;end
   if(hit(x,y,712,360,848,432)||hit(x,y,856,360,992,432)||hit(x,y,1000,360,1080,432)||hit(x,y,1280,360,1360,432))begin layer3=BUTTON;valid3=1;end
   if(hit(x,y,1088,360,1272,432))begin layer3=24'h1d2a3c;valid3=1;end
   if(hit(x,y,1104,410,1104+vol_width,416))begin layer3=24'h8ce2b3;valid3=1;end
   if(hit(x,y,16,344,16+loop_width,350))begin layer3=24'h8ce2b3;valid3=1;end
   for(i3=0;i3<4;i3=i3+1)if(hit(x,y,16+i3*96,324,96+i3*96,340))begin layer3=button_color(state[120:119]==i3);valid3=1;end
  end
 end
 always @(posedge pixel_clock)begin layer3_q<=layer3;valid3_q<=valid3;end
 reg [23:0] layer4,layer4_q;reg valid4,valid4_q;integer i4;reg [4:0] level4;
 always @*begin
 layer4=BG;valid4=0;level4=0;
    if(page==1 || page==2)begin
   for(i4=0;i4<4;i4=i4+1)if(hit(x,y,8,96+i4*84,216,168+i4*84))begin layer4=button_color(subpage==i4);valid4=1;end
   if(hit(x,y,232,96,1720,432))begin layer4=PANEL;valid4=1;end
   if(page==1)begin
    if(subpage==0 || subpage==2)for(i4=0;i4<4;i4=i4+1)
     if(hit(x,y,248+i4*364,140,596+i4*364,212))begin layer4=button_color((subpage==0?reverb:waveform)==i4);valid4=1;end
    if(subpage==0 || subpage==1 || subpage==3)begin
     for(i4=0;i4<2;i4=i4+1)begin
      if(hit(x,y,496,248+i4*96,576,320+i4*96)||hit(x,y,1536,248+i4*96,1616,320+i4*96))begin layer4=BUTTON;valid4=1;end
      if(hit(x,y,584,248+i4*96,1528,320+i4*96))begin layer4=24'h1d2a3c;valid4=1;end
     end
     if(hit(x,y,600,280,600+state[394:384],288))begin layer4=subpage==3?PURPLE:CYAN;valid4=1;end
     if(hit(x,y,600,376,600+state[410:400],384) && subpage!=3)begin layer4=CYAN;valid4=1;end
     if(subpage==1)for(i4=0;i4<5;i4=i4+1)if(hit(x,y,248+i4*292,140,528+i4*292,212))begin layer4=button_color({cfg[115],cfg[82:81]}==i4);valid4=1;end
    end
    if(subpage==2)for(i4=0;i4<4;i4=i4+1)begin
     if(hit(x,y,248+(i4%2)*736,248+(i4/2)*96,328+(i4%2)*736,320+(i4/2)*96)||hit(x,y,880+(i4%2)*736,248+(i4/2)*96,960+(i4%2)*736,320+(i4/2)*96))begin layer4=BUTTON;valid4=1;end
     if(hit(x,y,336+(i4%2)*736,248+(i4/2)*96,872+(i4%2)*736,320+(i4/2)*96))begin layer4=24'h1d2a3c;valid4=1;end
     if(hit(x,y,352+(i4%2)*736,280+(i4/2)*96,352+(i4%2)*736+((cfg[98-i4*5+:5])<<4),288+(i4/2)*96))begin layer4=CYAN;valid4=1;end
    end
   end
  end
 end
 always @(posedge pixel_clock)begin layer4_q<=layer4;valid4_q<=valid4;end
  // Calibration widgets use their own registered draw layer. This keeps
  // their hit tests out of the settings page's priority network.
  reg [23:0] cal_layer,cal_layer_q;reg cal_valid,cal_valid_q;integer ical;
  always @*begin
   cal_layer=BG;cal_valid=0;
   if(page==2)begin
    if(subpage==1 || subpage==2)begin
     for(ical=0;ical<4;ical=ical+1)begin
       if(hit(x,y,248+(ical%2)*472,184+(ical/2)*136,328+(ical%2)*472,256+(ical/2)*136)||hit(x,y,592+(ical%2)*472,184+(ical/2)*136,672+(ical%2)*472,256+(ical/2)*136))begin cal_layer=BUTTON;cal_valid=1;end
     end
     for(ical=0;ical<3;ical=ical+1)if(hit(x,y,1192+ical*172,148,1352+ical*172,220))begin cal_layer=button_color(state[102:101]==ical);cal_valid=1;end
     if(hit(x,y,1192,264,1436,336)||hit(x,y,1448,264,1704,336))begin cal_layer=BUTTON;cal_valid=1;end
    end else if(hit(x,y,248,256,600,328)||hit(x,y,616,256,968,328)||hit(x,y,984,256,1336,328))begin cal_layer=BUTTON;cal_valid=1;end
   end
  end
  always @(posedge pixel_clock)begin cal_layer_q<=cal_layer;cal_valid_q<=cal_valid;end
 reg [23:0] layer5,layer5_q;reg valid5,valid5_q;integer i5;reg [4:0] level5;
 always @*begin
 layer5=BG;valid5=0;level5=0;
  if(page==3)begin
   for(i5=0;i5<3;i5=i5+1)if(hit(x,y,8+i5*320,96,320+i5*320,168))begin layer5=button_color(subpage==i5);valid5=1;end
   if(hit(x,y,976,96,1184,168))begin layer5=BUTTON;valid5=1;end
   if(hit(x,y,1200,96,1720,432)||hit(x,y,120,216,1184,432))begin layer5=PANEL;valid5=1;end
   if(subpage==1)begin
    for(i5=0;i5<4;i5=i5+1)if(hit(x,y,8+i5*112,352,112+i5*112,424))begin layer5=button_color(state[29:24]==(i5==0?4:i5==1?8:i5==2?16:32));valid5=1;end
   end else for(i5=0;i5<3;i5=i5+1)if(hit(x,y,8,192+i5*80,104,264+i5*80))begin layer5=button_color(i5==0 && state[248]);valid5=1;end
  end
 end
 always @(posedge pixel_clock)begin layer5_q<=layer5;valid5_q<=valid5;end
 reg [23:0] layer6,layer6_q;reg valid6,valid6_q;integer i6;reg [4:0] level6;
 always @*begin
 layer6=BG;valid6=0;level6=0;
  if(state[118:117]!=0)begin
   if(hit(x,y,320,state[118:117]==2?24:88,1216,state[118:117]==2?432:344))begin layer6=PANEL;valid6=1;end
   if(hit(x,y,360,state[118:117]==2?352:256,672,state[118:117]==2?424:328)||hit(x,y,696,state[118:117]==2?352:256,1040,state[118:117]==2?424:328))begin layer6=BUTTON;valid6=1;end
   if(state[118:117]==2)begin
    if(hit(x,y,360,120,440,192)||hit(x,y,1056,120,1136,192)||hit(x,y,360,240,440,312)||hit(x,y,1056,240,1136,312))begin layer6=BUTTON;valid6=1;end
    if(hit(x,y,448,120,1048,192)||hit(x,y,448,240,1048,312))begin layer6=24'h1d2a3c;valid6=1;end
    if(hit(x,y,464,180,464+od_width,186))begin layer6=24'h8ce2b3;valid6=1;end
    if(hit(x,y,464,300,464+click_width,306))begin layer6=CYAN;valid6=1;end
   end
  end
 end
 always @(posedge pixel_clock)begin layer6_q<=layer6;valid6_q<=valid6;end
 reg [23:0] layer7,layer7_q;reg valid7,valid7_q;integer i7;reg [4:0] level7;
 always @*begin
 layer7=BG;valid7=0;level7=0;
  if(page==2 && subpage==0 && state[455])begin
   if((x>=state[458+:11]-12 && x<state[458+:11]+12 && y==state[469+:9]) ||
      (x==state[458+:11] && y>=state[469+:9]-12 && y<state[469+:9]+12))begin layer7=PURPLE;valid7=1;end
  end
 end
 always @(posedge pixel_clock)begin layer7_q<=layer7;valid7_q<=valid7;end
 always @*begin
 geometry=BG;
 if(valid0_q)geometry=layer0_q;
 if(valid1_q)geometry=layer1_q;
 if(drum_valid_q)geometry=drum_layer_q;
 if(valid2_q)geometry=layer2_q;
 if(valid3_q)geometry=layer3_q;
 if(valid4_q)geometry=layer4_q;
  if(cal_valid_q)geometry=cal_layer_q;
 if(valid5_q)geometry=layer5_q;
 if(valid6_q)geometry=layer6_q;
 if(valid7_q)geometry=layer7_q;
 end
 reg [10:0] x1,x2,x3;reg [8:0] y1,y2,y3;reg [3:0] controls1,controls2,controls3;
 reg spectrum_overlay1,cursor_overlay1;
 reg xy_inside1;reg [23:0] xy_background1,xy_color1;
 wire [11:0] raw_peak=raw_level[11:0]>raw_level[23:12]?raw_level[11:0]:raw_level[23:12];
 reg [23:0] bg1,bg2,bg3,fg1,fg2,fg3;reg [7:0] glyph2;reg [15:0] chinese_bits;
 (* syn_ramstyle="block_ram" *)reg [15:0] chinese_rom[0:3071];
 initial $readmemh("console_glyphs.mem",chinese_rom);
 wire [7:0] ascii_bits;ui_font ascii(.ch({1'b0,tile_data[5:0]}+7'd32),.row(y1[4:1]),.bits(ascii_bits));
 reg [7:0] row2,row3;reg ready1,ready2,ready3;
 always @(posedge pixel_clock)begin
  x1<=x;y1<=y;controls1<={den,hs,vs,ls};ready1<=ready && y<416;
  spectrum_overlay1<=(page==0 && state[118:117]==0 && hit(x,y,1368,328,1720,426) && spectrum_column<8 && spec_level>0 && y>=426-(spec_level>>4)) ||
    (page==3 && hit(x,y,120,240,1184,subpage==1?336:368) && (raw_peak>>4)>(subpage==1?336:368)-y);
  cursor_overlay1<=page==3 && x==cursor_x && y>=240 && y<368;
  xy_inside1<=page==0 && state[118:117]==0 && hit(x,y,592,112,1104,272);
  xy_color1<=xy_color;
  xy_background1<=(xy_x==64 || xy_y==63)?24'h52677e:
    (xy_x[4:0]==0 || xy_y[4:0]==31)?24'h233248:24'h080e18;
  fg1<=page==0 && x<560 && y<80?ORANGE:page==0 && y>=96 && y<128?(x<560?CYAN:x<1128?24'h8ce2b3:PURPLE):WHITE;
  x2<=x1;y2<=y1;controls2<=controls1;
  bg2<=xy_inside1?(xy_pixel?xy_color1:xy_background1):cursor_overlay1?ORANGE:spectrum_overlay1?CYAN:geometry;
  glyph2<=tile_data;ready2<=ready1;
  fg2<=fg1;
  row2<=ascii_bits;
  chinese_bits<=chinese_rom[((tile_data-64)<<4)+y1[4:1]];
  x3<=x2;y3<=y2;controls3<=controls2;bg3<=bg2;ready3<=ready2;
  fg3<=fg2;
  row3<=glyph2>=64?(x2[4]?chinese_bits[7:0]:chinese_bits[15:8]):row2;
 end
 assign video_pixel=ready3 && row3[7-x3[3:1]]?fg3:bg3;
 assign {video_den,video_hsync,video_vsync,video_line_start}=controls3;
endmodule
