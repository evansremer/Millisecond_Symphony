#include "console_ui.h"
#include "loop_ui.h"
#include "console_glyphs.h"
#include "tinyf_theremin.h"
#include "audio_midi.h"
#include "bt_score.h"
#include <string.h>
#include <stdio.h>

#ifdef CONSOLE_HOST_TEST
extern uint32_t console_test_read(unsigned);
extern void console_test_write(unsigned,uint32_t);
#define rr console_test_read
#define wr console_test_write
#else
static uint32_t rr(unsigned o){__asm__ volatile("fence iorw, iorw":::"memory");return *(volatile uint32_t*)(uintptr_t)(0xf8000500u+o);}
static void wr(unsigned o,uint32_t v){*(volatile uint32_t*)(uintptr_t)(0xf8000500u+o)=v;__asm__ volatile("fence iorw, iorw":::"memory");}
#endif
console_ui_state console_ui;
static uint16_t tiles[1560];
static uint32_t ui_words[16],config[4],next_frame,last_gain_ms,last_fs_ms,last_samples;
static unsigned upload,uploading,present,ready_bits;static uint32_t errors;
static int capture,contact;static unsigned tx,ty,last_touch_down;
static uint16_t smooth_gain[5];
static uint16_t points[5][2];static int32_t preview[4];
static uint16_t cross_x,cross_y,display_pitch;
static uint32_t midi_last_ms[2];
static uint8_t overflow_seen,config_dirty,swallow_stop,cancel_ui,fs_seeded;
static uint32_t stop_started,calibration_started;
static uint8_t score_mode,saved_laser,saved_click;static uint16_t score_cfg,score_committed;static int8_t saved_octave;
enum {C_NONE=-1,C_MASTER=1,C_DRY,C_WET,C_WIDTH,C_PAN,C_MIX,C_A,C_D,C_S,C_R,C_SPECTRUM,C_LOOP};

static uint32_t decode(const char **p)
{
 const unsigned char *s=(const unsigned char*)*p;uint32_t n;
 if(*s<128){*p+=1;return *s;}
 if((*s&224)==192){n=(s[0]&31)*64u+(s[1]&63);*p+=2;return n;}
 if((*s&240)==224){n=(s[0]&15)*4096u+(s[1]&63)*64u+(s[2]&63);*p+=3;return n;}
 *p+=1;return '?';
}
static void put(unsigned x,unsigned y,const char *s)
{
 unsigned col=x/16,row=y/32;
 while(*s && row<13){
  uint32_t cp=decode(&s);unsigned i;
  if(cp<128){if(cp>='a' && cp<='z')cp-=32;if(cp<32 || cp>95)cp='?';if(col<120)tiles[row*120+col]=(uint16_t)(cp-32);++col;}
  else{
   for(i=0;i<CONSOLE_GLYPH_COUNT && console_codepoints[i]!=cp;++i){}
   if(i<CONSOLE_GLYPH_COUNT){if(col&1u)++col;if(col<120)tiles[row*120+col]=(uint16_t)(64+i);++col;if(col<120)tiles[row*120+col]=(uint16_t)(64+i);++col;}
   else {if(col<120)tiles[row*120+col]='?'-32;++col;}
  }
 }
}
static void number(unsigned x,unsigned y,unsigned n,const char *suffix)
{char b[48];snprintf(b,sizeof b,"%u%s",n,suffix);put(x,y,b);}
static void signed_number(unsigned x,unsigned y,int n){char b[20];snprintf(b,sizeof b,"%+d",n);put(x,y,b);}
static unsigned clamp(int value,unsigned lo,unsigned hi){return value<(int)lo?lo:value>(int)hi?hi:(unsigned)value;}
static unsigned popcount(uint32_t x){unsigned n=0;while(x){n+=x&1u;x>>=1;}return n;}
static int inside(unsigned x,unsigned y,unsigned l,unsigned t,unsigned r,unsigned b){return x>=l && x<r && y>=t && y<b;}
static unsigned sub(void){return console_ui.subpage[console_ui.page];}
static void bits(unsigned offset,unsigned width,uint32_t value)
{for(unsigned i=0;i<width;++i){unsigned b=offset+i;config[b/32]=(config[b/32]&~(1u<<(b%32)))|(((value>>i)&1u)<<(b%32));}}
static void pack_config(void)
{
 console_ui_state *u=&console_ui;memset(config,0,sizeof config);
 bits(0,18,(uint32_t)smooth_gain[3]<<8);bits(18,18,(uint32_t)smooth_gain[2]<<8);
 bits(36,18,(uint32_t)smooth_gain[1]<<8);bits(54,18,(uint32_t)smooth_gain[0]<<8);
 bits(72,5,smooth_gain[4]);bits(77,2,u->waveform);bits(79,2,u->reverb);bits(81,2,u->eq);
 bits(83,5,u->adsr[3]);bits(88,5,u->adsr[2]);bits(93,5,u->adsr[1]);bits(98,5,u->adsr[0]);
 bits(103,3,(uint8_t)u->octave&7u);bits(106,2,u->instrument);
 bits(108,5,u->test_count&31u);bits(113,1,u->test_count!=0);bits(114,1,u->test_count>>5);bits(115,1,u->eq>>2);
}
static void request_stop(void)
{stop_started=last_gain_ms;console_ui.stopped=1;console_ui.test_count=0;console_ui.laser=0;wr(8,1);config_dirty=1;capture=C_NONE;}
static void set_parameter(int id,unsigned value)
{
 console_ui_state *u=&console_ui;
 switch(id){
 case C_MASTER:u->gain[3]=(uint16_t)clamp((int)value,0,1023);break;
 case C_DRY:u->gain[0]=(uint16_t)clamp((int)value,0,1023);break;
 case C_WET:u->gain[1]=(uint16_t)clamp((int)value,0,1023);break;
 case C_WIDTH:u->gain[2]=(uint16_t)clamp((int)value,0,1023);break;
 case C_PAN:u->gain[4]=(uint16_t)clamp((int)value,0,31);break;
 case C_MIX:u->mix=(uint8_t)clamp((int)value,0,100);break;
 case C_A:case C_D:case C_S:case C_R:u->adsr[id-C_A]=(uint16_t)clamp((int)value,0,31);break;
 default:break;
 }
 config_dirty=1;
}
static unsigned get_parameter(int id)
{switch(id){case C_MASTER:return console_ui.gain[3];case C_DRY:return console_ui.gain[0];case C_WET:return console_ui.gain[1];case C_WIDTH:return console_ui.gain[2];case C_PAN:return console_ui.gain[4];case C_MIX:return console_ui.mix;default:return id>=C_A && id<=C_R?console_ui.adsr[id-C_A]:0;}}
static unsigned maximum(int id){return id==C_PAN || id>=C_A?31:id==C_MIX?100:1023;}
static void adjust(int id,int delta){set_parameter(id,clamp((int)get_parameter(id)+delta,0,maximum(id)));}
static void slider(int id,unsigned x,unsigned left,unsigned right)
{unsigned q=clamp((int)x,left,right)-left;set_parameter(id,(q*maximum(id)+(right-left)/2)/(right-left));}
static void spectrum_cursor(unsigned x)
{unsigned last=511u>>console_ui.zoom;console_ui.cursor=(uint16_t)(((clamp((int)x,120,1183)-120)*last+531u)/1063u);}
static void defaults(void)
{
 console_ui.pending_near[0]=console_ui.pending_near[1]=100;
 console_ui.pending_far[0]=console_ui.pending_far[1]=600;
 console_ui.pending_low=48;console_ui.pending_high=72;console_ui.response=1;
}
static void apply_laser(void)
{
 static const unsigned tau[]={5,25,50};
 if(tinyf_theremin_set_mapping(console_ui.pending_near,console_ui.pending_far,console_ui.pending_low,console_ui.pending_high,tau[console_ui.response])==0)config_dirty=1;
}
static void start_test(unsigned count)
{
 if(bt_score_active() || console_ui.stopped || tinyf_diagnostics.config_phase || loop_ui_active())return;
 console_ui.test_count=(uint8_t)count;config_dirty=1;
}
static void calibrate_press(unsigned x,unsigned y)
{
 unsigned n=console_ui.calibration_stage-1u;
 if(n<5){points[n][0]=(uint16_t)x;points[n][1]=(uint16_t)y;}
}
static void calibrate_release(void)
{
 console_ui_state *u=&console_ui;
 if(u->calibration_stage<1 || u->calibration_stage>5)return;
 if(++u->calibration_stage==6){
  int x0=(points[0][0]+points[3][0])/2,x1=(points[1][0]+points[2][0])/2;
  int y0=(points[0][1]+points[1][1])/2,y1=(points[2][1]+points[3][1])/2;
  u->calibration_valid=0;
  if(x1-x0<700 || y1-y0<100)return;
  preview[0]=(int32_t)((1504LL<<16)/(x1-x0));preview[1]=(int32_t)((256LL<<16)/(y1-y0));
  preview[2]=(96<<16)-preview[0]*x0;preview[3]=(112<<16)-preview[1]*y0;
  static const uint16_t targets[5][2]={{96,112},{1600,112},{1600,368},{96,368},{848,240}};
  for(unsigned i=0;i<5;++i){
   int xx=(int)(((int64_t)preview[0]*points[i][0]+preview[2])>>16);
   int yy=(int)(((int64_t)preview[1]*points[i][1]+preview[3])>>16);
   if(xx<(int)targets[i][0]-48 || xx>(int)targets[i][0]+48 || yy<(int)targets[i][1]-32 || yy>(int)targets[i][1]+32)return;
  }
  u->calibration_valid=1;
 }
}
static void press(unsigned x,unsigned y,unsigned raw_x,unsigned raw_y)
{
 console_ui_state *u=&console_ui;unsigned group=sub();capture=C_NONE;
 if(inside(x,y,1728,340,1912,432)){
  if(swallow_stop)return;
  if(u->stopped){if(last_gain_ms-stop_started<30)return;u->stopped=0;wr(8,0);config_dirty=1;}else request_stop();return;
 }
 for(unsigned i=0;i<4;++i)if(inside(x,y,1728,8+i*80,1912,80+i*80)){
  u->page=(uint8_t)i;loop_ui_page_changed();u->maintenance_confirm=0;u->calibration_stage=0;return;
 }
 if(loop_ui_press(x,y,u->page,u->stopped,u->test_count)){if(loop_ui.capture)capture=C_LOOP;return;}
 if(u->calibration_stage>=1 && u->calibration_stage<=5){calibrate_press(raw_x,raw_y);capture=100;return;}
 if(inside(x,y,1064,8,1144,80)){adjust(C_MASTER,-1);return;}
 if(inside(x,y,1512,8,1592,80)){adjust(C_MASTER,1);return;}
 if(inside(x,y,1152,8,1504,80)){capture=C_MASTER;slider(capture,x,1170,1484);return;}
 if(inside(x,y,1600,8,1720,80)){u->muted^=1;config_dirty=1;return;}
 if(u->page==0){
  for(unsigned i=0;i<3;++i)if(inside(x,y,20+i*176,112,188+i*176,184)){u->instrument=(uint8_t)i;config_dirty=1;return;}
  if(inside(x,y,20,200,100,272)){if(!score_mode && u->octave>-3)--u->octave;config_dirty=1;}
  if(inside(x,y,212,200,292,272)){if(!score_mode && u->octave<3)++u->octave;config_dirty=1;}
  if(inside(x,y,1148,112,1244,184) && !u->stopped && !score_mode){u->laser^=1;config_dirty=1;}
  if(inside(x,y,1148,200,1228,272))adjust(C_MIX,-1);
  if(inside(x,y,1628,200,1708,272))adjust(C_MIX,1);
 }else if(u->page==1 || u->page==2){
  for(unsigned i=0;i<4;++i)if(inside(x,y,8,96+i*84,216,168+i*84)){
   u->subpage[u->page]=(uint8_t)i;u->maintenance_confirm=0;u->calibration_stage=0;return;
  }
  if(u->page==1){
   if(group==1){
    for(unsigned i=0;i<5;++i)if(inside(x,y,248+i*292,140,528+i*292,212)){u->eq=(uint8_t)i;config_dirty=1;return;}
   }else if(group==0 || group==2)for(unsigned i=0;i<4;++i)if(inside(x,y,248+i*364,140,596+i*364,212)){
    if(group==0)u->reverb=(uint8_t)i;else u->waveform=(uint8_t)i;config_dirty=1;return;
   }
   if(group==2){
    for(unsigned i=0;i<4;++i){unsigned l=248+(i%2)*736,t=248+(i/2)*96;
     if(inside(x,y,l,t,l+80,t+72))adjust(C_A+(int)i,-1);
     if(inside(x,y,l+632,t,l+712,t+72))adjust(C_A+(int)i,1);
     if(inside(x,y,l+88,t,l+624,t+72)){capture=C_A+(int)i;slider(capture,x,l+104,l+608);}
    }
   }else{
    int ids[2]={group==0?C_DRY:group==1?C_PAN:C_MIX,group==0?C_WET:C_WIDTH};
    for(unsigned i=0;i<(group==3?1u:2u);++i){unsigned t=248+i*96;
     if(inside(x,y,496,t,576,t+72))adjust(ids[i],-1);
     if(inside(x,y,1536,t,1616,t+72))adjust(ids[i],1);
     if(inside(x,y,584,t,1528,t+72)){capture=ids[i];slider(capture,x,600,1512);}
    }
   }
  }else if(group==1 || group==2){
   unsigned sensor=group-1;
   for(unsigned i=0;i<4;++i){unsigned l=248+(i%2)*472,t=184+(i/2)*136;int delta=0;
    if(inside(x,y,l,t,l+80,t+72))delta=-1;
    if(inside(x,y,l+344,t,l+424,t+72))delta=1;
    if(delta){
     if(i==0)u->pending_near[sensor]=(uint16_t)clamp((int)u->pending_near[sensor]+delta*10,20,u->pending_far[sensor]-10u);
     if(i==2)u->pending_far[sensor]=(uint16_t)clamp((int)u->pending_far[sensor]+delta*10,u->pending_near[sensor]+10u,4000);
     if(i==1 && sensor==0)u->pending_high=(uint8_t)clamp((int)u->pending_high+delta,u->pending_low+1u,84);
     if(i==3 && sensor==0)u->pending_low=(uint8_t)clamp((int)u->pending_low+delta,36,u->pending_high-1u);
    }
   }
   for(unsigned i=0;i<3;++i)if(inside(x,y,1192+i*172,148,1352+i*172,220))u->response=(uint8_t)i;
   if(inside(x,y,1192,264,1436,336))apply_laser();
   if(inside(x,y,1448,264,1704,336))defaults();
  }else if(group==0){
   if(inside(x,y,248,256,600,328)){u->calibration_stage=1;calibration_started=last_gain_ms;u->calibration_valid=0;}
   if(inside(x,y,616,256,968,328) && u->calibration_stage==6 && u->calibration_valid){u->cal_sx=preview[0];u->cal_sy=preview[1];u->cal_ox=preview[2];u->cal_oy=preview[3];u->calibration_stage=0;}
   if(inside(x,y,984,256,1336,328)){u->calibration_stage=0;}
  }else{
   if(inside(x,y,248,256,600,328) && !tinyf_diagnostics.config_phase){
    if(score_mode)return;
    if(u->maintenance_confirm){++u->config_request;u->maintenance_confirm=0;u->laser=0;config_dirty=1;}else u->maintenance_confirm=1;
   }
   if(inside(x,y,616,256,968,328))u->maintenance_confirm=0;
  }
 }else{
  for(unsigned i=0;i<3;++i)if(inside(x,y,8+i*320,96,320+i*320,168)){u->subpage[3]=(uint8_t)i;return;}
  if(inside(x,y,976,96,1184,168)){if(u->test_count)u->test_count=0;else start_test(group==1?u->test_load:4);config_dirty=1;}
  if(group==1){
   static const uint8_t counts[4]={4,8,16,32};
   for(unsigned i=0;i<4;++i)if(inside(x,y,8+i*112,352,112+i*112,424)){u->test_load=counts[i];if(u->test_count){u->test_count=counts[i];config_dirty=1;}}
   return;
  }
  if(inside(x,y,8,192,104,264))u->freeze^=1;
  if(inside(x,y,8,272,104,344))u->cursor=(uint16_t)((u->cursor+1u)%(512u>>u->zoom));
  if(inside(x,y,8,352,104,424)){u->zoom=(uint8_t)((u->zoom+1u)%6u);u->cursor=(uint16_t)clamp(u->cursor,0,511u>>u->zoom);}
  if(inside(x,y,120,240,1184,368)){capture=C_SPECTRUM;spectrum_cursor(x);}
 }
}
static void move(unsigned x)
{
 if(capture==C_LOOP)loop_ui_move(x);
 else if(capture==C_MASTER)slider(capture,x,1170,1484);
 else if(capture>=C_A && capture<=C_R){unsigned l=248+((unsigned)(capture-C_A)%2)*736;slider(capture,x,l+104,l+608);}
 else if(capture>=C_DRY && capture<=C_MIX)slider(capture,x,600,1512);
 else if(capture==C_SPECTRUM)spectrum_cursor(x);
}
static unsigned laser_state(uint32_t now)
{
 tinyf_status *t=&tinyf_diagnostics;
 if(!console_ui.laser)return 0;
 if(t->config_phase)return 1;
 for(unsigned i=0;i<2;++i)if(!t->sensor[i].have_valid || now-t->sensor[i].last_valid_ms>=120)return 2;
 for(unsigned i=0;i<2;++i)if(t->sensor[i].distance_mm>tinyf_theremin_mapping(i*2+1)+50u)return 3;
 return t->playing?5:4;
}
static void note_text(unsigned x,unsigned y,unsigned note)
{static const char *names[]={"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"};char b[12];snprintf(b,sizeof b,"%s%d",names[note%12],(int)(note/12)-1);put(x,y,b);}
static void controls_text(unsigned now)
{
 console_ui_state *u=&console_ui;char b[96];unsigned group=sub(),ls=laser_state(now);
 memset(tiles,0,sizeof tiles);for(unsigned i=0;i<1560;++i)tiles[i]=0;
 put(832,0,"输出 L/R");put(1072,32,"-");put(1168,0,"主音量");number(1328,0,u->gain[3]*100u/1023u,"%");put(1536,32,"+");put(1616,32,u->muted?"有声":"静音");
 static const char *pages[]={"演奏","音效","校准","验证"};for(unsigned i=0;i<4;++i)put(1776,32+i*80,pages[i]);
 put(1776,352,u->stopped?"恢复":"止音");put(1744,384,u->stopped?"已止音":"锁止触发");
 // Compact, persistent Loop telemetry leaves the keyboard's header to drums.
 const char *loop_name=bt_status.present && bt_status.state!=BT_IDLE?bt_score_name():loop_ui_state_name();
 if(!(bt_status.present && bt_status.state!=BT_IDLE)){
  if(strstr(loop_name,"FAULT"))loop_name="LOOP DDR FAULT";
  else if(strstr(loop_name,"DDR WAIT"))loop_name="LOOP DDR WAIT";
  else if(strstr(loop_name,"UNAVAILABLE"))loop_name="LOOP N/A";
 }
 put(576,0,loop_name);
 if(bt_score_active()){number(576,32,bt_status.position_ms/1000u,"S SOLO");}
 else if(u->muted && ((loop_ui.status[0]&15u)==3 || (loop_ui.status[4]&4u)))put(576,32,"MUTED + REC");
 else if(loop_ui.status[4]&0x7au){snprintf(b,sizeof b,"WAIT %u BEATS",(unsigned)((loop_ui.status[4]>>18)&63u));put(576,32,b);}
 else if(u->test_count)put(576,32,"TEST ACTIVE");
 if(u->page==0){
  put(16,96,"键盘");put(48,128,"钢琴");put(224,128,"圆号");put(400,128,"合成器");
  put(16,192,"八度");put(48,224,"-");signed_number(128,224,u->octave);put(240,224,"+");
  unsigned x=304;for(unsigned i=0;i<32 && x<544;++i)if(u->audio[3]&(1u<<i)){note_text(x,192,i+41);x+=80;}
  snprintf(b,sizeof b,"%u声部 V%u",popcount(u->audio[0]&65535u)+popcount(u->audio[0]>>16)+popcount(u->audio[1]),(unsigned)u->last_velocity[0]);put(304,224,b);
  static const char *drums[]={"高嗵","中嗵","低嗵","底鼓","军鼓","边击","闭镲","开镲","吊镲","叮镲"};
  for(unsigned i=0;i<10;++i){unsigned xx=((i%5)*112u+31u)&~31u,yy=(i/5)*32;put(xx,yy,drums[i]);number(xx+64,yy,u->audio[12+i],"");}
  // Display-only phase mapping, normalized rectangular axes.
  put(576,80,"XY PHASE12 / L-R");
  static const char *states[]={"已关闭","配置中","数据失效","超出范围","等待双手","正在演奏"};
  put(1136,96,states[ls]);put(1152,128,u->laser?"ON":"OFF");
  for(unsigned i=0;i<2;++i){
   tinyf_sensor *s=&tinyf_diagnostics.sensor[i];put(1264,96+i*32,i?"响度":"音高");
   if(s->have_valid && now-s->last_valid_ms<120){snprintf(b,sizeof b,"%u.%ucm",s->distance_mm/10,s->distance_mm%10);put(1344,96+i*32,b);}else put(1344,96+i*32,"--cm");
  }
  put(1152,224,"-");number(1344,224,u->mix,"%混合");put(1648,224,"+");
  note_text(1152,160,tinyf_theremin_mapping(5));note_text(1664,160,tinyf_theremin_mapping(4));
  number(1504,96,u->audio[4]*100u/65536u,"%");
  if(u->fs_reference && ls==5)number(1504,96,(unsigned)(((uint64_t)u->audio[10]*u->fs_reference)>>32),"Hz");else put(1504,96,"--Hz");
  put(1376,288,"实时输出频谱");
  put(24,288,"-");number(112,288,loop_ui.bpm,"");put(224,288,"+");put(304,288,"TAP");
  static const unsigned lb[]={1,2,4,8};for(unsigned i=0;i<4;++i)number(432+i*112,288,lb[i],"BAR");
  put(864,288,loop_ui.click?"CLK ON":"CLICK");put(992,288,"SET");
  snprintf(b,sizeof b,"BAR%u/%u 4/4",((loop_ui.status[4]>>12)&63u)/4+1,loop_ui.bars);put(1088,288,b);
  unsigned waits=(loop_ui.status[4]>>18)&63u;
  if(loop_ui.status[0]%16==1 || loop_ui.status[0]%16==2 || (loop_ui.status[4]&0x7au))snprintf(b,sizeof b,"WAIT %u BEATS",waits);
  else snprintf(b,sizeof b,"BEAT%u/4 %u%%",((loop_ui.status[4]>>12)&3u)+1,loop_ui_progress()/10);
  put(1088,320,b);
  unsigned st=loop_ui.status[0]&15u,lf=loop_ui.status[4];
  put(24,384,st>=1&&st<=3?"CANCEL REC":"RECORD");put(200,384,(lf&16u)?"CANCEL":"PLAY");
  put(376,384,(lf&6u)?"CANCEL OD":"OVERDUB");put(552,384,(lf&8u)?"CANCEL":"STOP");
  put(728,384,"UNDO");put(872,384,(lf&64u)?"CANCEL":"CLEAR");put(1016,384,"-");put(1296,384,"+");
  number(1120,352,loop_ui.volume,"% LOOP");
  if(loop_ui.pressed)put(8,320,loop_ui_press_name());
  if(loop_ui.notice || ((loop_ui.status[7]>>16)&255u))put(416,320,loop_ui.notice==3?"LOCKED: CLEAR FIRST":loop_ui.notice==5?"CANCEL TAKE FIRST":"COMMAND BUSY / REJECTED");
  else if(loop_ui.parameter_pending)put(416,320,"APPLY NEXT BAR");
  else if(st==6)put(416,320,"DDR FAULT: SET > RECOVER");
  else {snprintf(b,sizeof b,"OLD100 / OD%u%% CLIP%lu",loop_ui.overdub_volume,(unsigned long)loop_ui.status[10]);put(416,320,b);}
 }else if(u->page==1){
  static const char *g[]={"总混响","EQ与输出","合成器","激光混合"};for(unsigned i=0;i<4;++i)put(32,128+i*84,g[i]);
  if(group==0 || group==1 || group==2){
   static const char *rv[]={"HALL","ROOM","PLATE","OFF"},*eq[]={"电话音","清晰","暖低音","明亮","失真"},*wv[]={"正弦","方波","三角","锯齿"};
   if(group==1){for(unsigned i=0;i<5;++i)put(312+i*292,160,eq[i]);}
   else for(unsigned i=0;i<4;++i)put(320+i*364,160,group==0?rv[i]:wv[i]);
  }
  put(248,96,group==0?"总混响:所有输入":group==1?(u->eq==4?"失真:键盘鼓组和激光 / 高电平":"EQ:仅键盘和鼓组"):group==2?"波形与ADSR:仅合成器":"特雷门琴混合");
  if(group==2){
   for(unsigned i=0;i<4;++i){unsigned x=248+(i%2)*736,y=256+(i/2)*96;char label[16];snprintf(label,sizeof label,"%c: %u","ADSR"[i],u->adsr[i]);put(x+104,y,label);put(x+16,y,"-");put(x+656,y,"+");}
  }else{
   const char *l0=group==0?"干声电平":group==1?"干声声像":"激光比例";
   const char *l1=group==0?"湿声电平":"混响宽度";
   put(248,256,l0);put(512,256,"-");put(1552,256,"+");
   number(1632,256,group==0?u->gain[0]*100u/1023u:group==1?u->gain[4]:u->mix,group==1?"":"%");
   if(group!=3){put(248,352,l1);put(512,352,"-");put(1552,352,"+");number(1632,352,(group==0?u->gain[1]:u->gain[2])*100u/1023u,"%");}
   else {snprintf(b,sizeof b,"键盘鼓组%u%% / 激光上限%u%%",100-u->mix,u->mix);put(248,352,b);}
  }
 }else if(u->page==2){
  static const char *g[]={"触摸校准","音高手","响度手","模组维护"};for(unsigned i=0;i<4;++i)put(16,128+i*84,g[i]);
  if(group==1 || group==2){unsigned sensor=group-1;
   put(248,96,"距离");put(720,96,group==1?"连续音域":"实际响度");put(1192,96,"响应平滑设置");
   put(248,128,"近端");put(248,288,"远端");
   for(unsigned i=0;i<4;++i){unsigned x=248+(i%2)*472,y=192+(i/2)*136;put(x+16,y,"-");put(x+368,y,"+");}
   number(384,192,u->pending_near[sensor]/10,"cm");number(384,320,u->pending_far[sensor]/10,"cm");
   if(sensor==0){note_text(880,192,u->pending_high);note_text(880,320,u->pending_low);}else{put(864,192,"静音");put(864,320,"最响");}
   put(1216,160,"快速");put(1392,160,"均衡");put(1568,160,"稳定");put(1192,224,"平滑值非总延迟");
   put(1216,288,"应用映射");put(1472,288,"恢复默认");put(1192,352,"改动后点击应用");
  }else if(group==0){
   put(248,96,"触摸五点校准 / RAM保存");
   if(u->calibration_stage>=1 && u->calibration_stage<=5){number(248,160,u->calibration_stage,"/5 点击十字");}
   else put(248,160,u->calibration_stage==6?(u->calibration_valid?"校准有效:应用":"校准无效:不改"):"五点采集");
   put(288,288,"开始校准");put(672,288,"应用");put(1040,288,"取消");
  }else{
   put(248,96,"模组维护:手动SET90HZ");
   number(248,160,tinyf_diagnostics.sensor[0].measured_millihz/1000,"Hz 音高实测");number(784,160,tinyf_diagnostics.sensor[1].measured_millihz/1000,"Hz 响度实测");
   put(248,224,tinyf_diagnostics.config_phase?"配置忙:禁止重复":"TX完成 / 无ACK");
   put(272,288,u->maintenance_confirm?"确认SET90HZ":"SET90HZ");put(672,288,"取消");
   number(248,352,tinyf_diagnostics.config_requests,"次请求");
  }
 }else{
  put(48,128,"多频测试");put(368,128,"复音负载");put(688,128,"运行诊断");put(992,128,u->test_count?"停止测试":"启动测试");
  if(group==1){static const unsigned loads[]={4,8,16,32};for(unsigned i=0;i<4;++i)number(32+i*112,384,loads[i],"");}else{put(16,224,u->freeze?"实时":"冻结");put(16,288,"CUR");put(16,384,"放大");}
  put(1216,96,"运行与测量");
  if(group==2){number(1216,128,u->audio[8]," AUDIO FLAGS");number(1216,160,errors," MIDI DECODE");number(1216,192,audio_queue_overflows," SW QUEUE");number(1216,224,audio_fifo_rejections," HW FIFO");
   snprintf(b,sizeof b,"RANGE/SLOT %u/%u",(unsigned)u->audio[22],(unsigned)u->audio[23]);put(1216,256,b);
   number(1216,288,u->audio[24]," FFT FLAGS");number(1216,320,u->touch_errors,"触摸错误");number(1216,352,u->heartbeat,"心跳");}
  else{
   put(128,192,u->test_count?"FPGA实时正弦测试 / AUTO AC":"观察 / 点击测试发声 AUTO AC");
   number(1216,160,popcount(u->audio[1]),"合成器声部");
   if(u->fs_reference)number(1216,192,u->fs_reference,"S/s参考");else put(1216,192,"Fs:待测");
   put(1216,288,"OSC:待核验");put(1216,320,"MIDI延迟:待实测");put(1216,352,"激光延迟:待实测");
   if(u->test_count==4 && u->fs_reference){
    static const uint32_t phases[4]={0x00b29a62u,0x016534c3u,0x02173456u,0x02ca6987u};
    for(unsigned i=0;i<4;++i){uint32_t mhz=(uint32_t)(((uint64_t)phases[i]*u->fs_reference*1000u)>>32);snprintf(b,sizeof b,"%u.%uHz SET",mhz/1000,(mhz%1000)/100);put(1216+(i%2)*240,224+(i/2)*32,b);}
   }else if(u->test_count && u->fs_reference){
    unsigned low=(unsigned)(((uint64_t)0x00773407u*u->fs_reference)>>32);
    unsigned high=(unsigned)(((uint64_t)(u->test_count==8?0x010b9a2bu:u->test_count==32?0x02ca6987u:0x02a250bau)*u->fs_reference)>>32);
    snprintf(b,sizeof b,"%u..%uHz SET",low,high);put(1216,224,b);
    snprintf(b,sizeof b,"MIDI41..%u STEP%u",u->test_count==32?72u:41u+(u->test_count-1u)*2u,u->test_count==32?1u:2u);put(1216,256,b);
   }else put(1216,224,"F:待计数 / 设置频率");
  }
  unsigned bin=u->cursor;
  snprintf(b,sizeof b,"bin%u: %uHz REF",bin,(unsigned)(((uint64_t)bin*u->fs_reference)/1024u));put(group==1?520:128,384,b);
  snprintf(b,sizeof b,"0..%uHz",(unsigned)(((uint64_t)(511u>>u->zoom)*u->fs_reference)/1024u));put(832,192,b);
 }
}
static void loop_modal_text(void)
{
 if(!loop_ui.modal)return;
 for(unsigned row=loop_ui.modal==2?1:3;row<=(loop_ui.modal==2?12:10);++row)for(unsigned col=20;col<76;++col)tiles[row*120+col]=0;
 put(352,loop_ui.modal==2?32:96,loop_ui.modal==1?"CLEAR LOOP? DEFAULT: CANCEL":"LOOP SETTINGS / VOLATILE DDR");
 if(loop_ui.modal==1){put(352,160,"ONE TRACK + UNDO WILL BE LOST");put(400,288,"CANCEL");put(728,288,"CONFIRM CLEAR");}
 else{
  put(352,88,"OVERDUB VOLUME");put(376,144,"-");put(1072,144,"+");number(896,88,loop_ui.overdub_volume,"%");
  put(352,208,"CLICK VOLUME");put(376,264,"-");put(1072,264,"+");number(896,208,loop_ui.click_volume,"%");
  number(352,320,loop_ui.status[10]," CLIPS / OLD LOOP 100%");put(400,368,"CLOSE");put(728,368,"RECOVER DDR");
 }
}
static void frame(unsigned now)
{
 console_ui_state *u=&console_ui;unsigned g=sub();
 controls_text(now);loop_modal_text();memset(ui_words,0,sizeof ui_words);
 ui_words[0]=u->page|((uint32_t)u->test_load<<24)|(g<<2)|((uint32_t)u->stopped<<4)|((uint32_t)u->muted<<5)|((uint32_t)u->test_count<<8);
 ui_words[1]=(u->laser&&!u->stopped?1u:0u)|((uint32_t)loop_ui.overdub_volume<<1)|((uint32_t)u->mix<<8)|((uint32_t)u->config_request<<16);
 ui_words[2]=tinyf_diagnostics.sensor[0].distance_mm|((uint32_t)tinyf_diagnostics.sensor[1].distance_mm<<16);
 ui_words[3]=laser_state(now)|((uint32_t)u->response<<5);
 // Pitch position derives from actual phase step, not nearest semitone.
 if(laser_state(now)==5)display_pitch=(uint16_t)tinyf_theremin_pitch_position(u->audio[10]);
 unsigned pitch=display_pitch;
 ui_words[4]=pitch|((120u+(u->cursor*1063u)/(511u>>u->zoom))<<20);ui_words[5]=u->audio[4];
 for(unsigned i=0;i<10;++i)ui_words[i<6?6:7]|=(u->audio[12+i]&31u)<<((i<6?i:i-6)*5);
 ui_words[7]|=((uint32_t)u->freeze<<24)|((uint32_t)u->zoom<<25)|((uint32_t)(u->cursor&15u)<<20);
 for(unsigned i=0;i<4;++i)ui_words[8+i]=config[i];
 int a=g==0?C_DRY:g==1?C_PAN:C_MIX,b=g==0?C_WET:C_WIDTH;
 ui_words[12]=(get_parameter(a)*912u/maximum(a))|((get_parameter(b)*912u/maximum(b))<<16);
 ui_words[13]=((u->audio[6]>>15)>198?198:u->audio[6]>>15)|(((u->audio[7]>>15)>198?198:u->audio[7]>>15)<<16);
 if(u->calibration_stage>=1 && u->calibration_stage<=5){
  static const uint16_t targets[5][2]={{96,112},{1600,112},{1600,368},{96,368},{848,240}};
  cross_x=targets[u->calibration_stage-1][0];cross_y=targets[u->calibration_stage-1][1];
  ui_words[14]=(1u<<7)|((uint32_t)cross_x<<10)|((uint32_t)cross_y<<21);
 }
 ui_words[15]=(1170u+(smooth_gain[3]*314u)/1023u)|((1160u+(pitch*535u)/1023u)<<11)|(((u->audio[4]*435u)/65536u)<<22);
 ui_words[0]|=(loop_ui_progress()*255u/1000u)<<16;
 ui_words[3]|=((loop_ui.status[0]&15u)<<8)|((loop_ui.status[4]&511u)<<12)|((uint32_t)loop_ui.modal<<21)|(((loop_ui.status[4]>>12)&3u)<<23)|((uint32_t)loop_ui.bars<<25);
 ui_words[5]|=((uint32_t)loop_ui.volume<<17)|((uint32_t)loop_ui.click_volume<<24);
 upload=0;uploading=1;wr(0x24,0);
}
void console_ui_midi(unsigned source,unsigned note,unsigned velocity)
{if(source>=1 && source<=2){console_ui.last_midi[source-1]=note;console_ui.last_velocity[source-1]=velocity;midi_last_ms[source-1]=last_gain_ms;}}
void console_ui_init(uint32_t now)
{
 memset(&console_ui,0,sizeof console_ui);memset(midi_last_ms,0,sizeof midi_last_ms);console_ui.cal_sx=console_ui.cal_sy=65536;
 console_ui.adsr[0]=12;console_ui.adsr[1]=20;console_ui.adsr[2]=24;console_ui.adsr[3]=18;
 console_ui.gain[0]=1023;console_ui.gain[1]=256;console_ui.gain[2]=1023;console_ui.gain[3]=819;console_ui.gain[4]=16;
 for(unsigned i=0;i<5;++i)smooth_gain[i]=console_ui.gain[i];
 console_ui.mix=25;console_ui.zoom=4;console_ui.test_load=32;defaults();present=rr(0)==0x55490102u;next_frame=last_gain_ms=last_fs_ms=now;
 loop_ui_init();display_pitch=512;capture=C_NONE;contact=0;uploading=0;config_dirty=1;fs_seeded=0;overflow_seen=0;cancel_ui=0;swallow_stop=0;last_touch_down=0;tinyf_theremin_console_control(0,25,0);pack_config();
}
void console_ui_poll(uint32_t now,unsigned ready_mask,uint32_t input_errors)
{
 if(!present)return;
 loop_ui_poll(now);
 if(console_ui.calibration_stage && now-calibration_started>30000u)console_ui.calibration_stage=0;
 console_ui_state *u=&console_ui;uint32_t flags=rr(4);ready_bits=ready_mask;errors=input_errors;++u->heartbeat;
 if((flags&(1u<<6)) && !u->stopped){swallow_stop=1;request_stop();}
 if(((flags>>5)&1u)!=overflow_seen){overflow_seen=(uint8_t)((flags>>5)&1u);cancel_ui=1;++u->touch_errors;contact=0;capture=C_NONE;last_touch_down=0;loop_ui_release();}
 for(unsigned k=0;k<4;++k){
  uint32_t e=rr(0x0c);if(e>>31)break;
  if(cancel_ui)continue;
  unsigned raw_x=1919u-(e&4095u),raw_y=(e>>12)&4095u,down=(e>>24)&1u;
  if(raw_x>1919 || raw_y>439){++u->touch_errors;continue;}
  tx=clamp((int)(((int64_t)u->cal_sx*raw_x+u->cal_ox)>>16),0,1919);
  ty=clamp((int)(((int64_t)u->cal_sy*raw_y+u->cal_oy)>>16),0,439);
  if(down && !last_touch_down){contact=1;press(tx,ty,raw_x,raw_y);}
  else if(down && contact)move(tx);
  else if(!down){loop_ui_release();swallow_stop=0;if(capture==100)calibrate_release();contact=0;capture=C_NONE;}
  last_touch_down=down;
 }
 // Latest physical release cancels a gesture even after a FIFO overflow.
 if(cancel_ui && !(rr(0x10)&(1u<<24)) && (flags&(1u<<3))){cancel_ui=0;contact=0;capture=C_NONE;last_touch_down=0;swallow_stop=0;loop_ui_release();}
 tinyf_theremin_console_control(u->laser&&!u->stopped,u->mix,u->config_request);
 if(now!=last_gain_ms){unsigned dt=now-last_gain_ms;last_gain_ms=now;if(dt>25)dt=25;
  for(unsigned i=0;i<5;++i){int target=i==3 && u->muted?0:u->gain[i];int delta=target-(int)smooth_gain[i];int step=i==4?1:(int)dt*8;
   if(delta>step)delta=step;
   if(delta< -step)delta=-step;
   if(delta){smooth_gain[i]=(uint16_t)((int)smooth_gain[i]+delta);config_dirty=1;}
  }
 }
 if(config_dirty && !(flags&2u)){
  pack_config();for(unsigned i=0;i<4;++i)wr(0x80+i*4,config[i]);wr(0x18,1);config_dirty=0;if(score_mode)score_committed=1;
 }
 if(uploading && !(flags&4u)){
  unsigned budget=48;
  while(budget-- && upload<1560)wr(0x28,tiles[upload++]);
  if(upload==1560){for(unsigned i=0;i<16;++i)wr(0x40+i*4,ui_words[i]);wr(0x20,1);uploading=0;++u->frames;}
 }
 if(!uploading && !(flags&4u) && (int32_t)(now-next_frame)>=0){
  next_frame=now+33;wr(0x38,1);for(unsigned i=0;i<32;++i){wr(0x30,i);u->audio[i]=rr(0x34);}
  if(!fs_seeded){last_samples=u->audio[9];last_fs_ms=now;fs_seeded=1;}
  else if(now-last_fs_ms>=1000){uint32_t elapsed=now-last_fs_ms;u->fs_reference=(uint32_t)(((uint64_t)(u->audio[9]-last_samples)*1000u)/elapsed);last_samples=u->audio[9];last_fs_ms=now;}
  frame(now);
 }
}

int console_score_begin(void){
 if(score_mode || console_ui.stopped || console_ui.test_count || !loop_ui_score_available() || tinyf_diagnostics.config_phase)return 0;
 score_cfg=(uint16_t)rr(0x14);score_committed=0;score_mode=1;saved_octave=console_ui.octave;saved_laser=console_ui.laser;saved_click=loop_ui.click;
 console_ui.octave=0;console_ui.laser=0;console_ui.maintenance_confirm=0;
 loop_ui_score_click(0);
 loop_ui.modal=0;loop_ui_release();capture=C_NONE;config_dirty=1;return 1;
}
void console_score_end(void){
 console_ui.octave=saved_octave;console_ui.laser=console_ui.stopped?0:saved_laser;
 score_cfg=(uint16_t)rr(0x14);score_committed=0;
 loop_ui_score_click(saved_click && !console_ui.stopped);
 config_dirty=1;
}

int console_score_ready(void){
 return score_mode && score_committed && (uint16_t)rr(0x14)!=score_cfg && !(rr(4)&2u)
  && !tinyf_diagnostics.enabled && !tinyf_diagnostics.gain && !tinyf_diagnostics.dirty && loop_ui_score_click_ready();
}

int console_score_restored(void){
 if(score_committed && (uint16_t)rr(0x14)!=score_cfg && !(rr(4)&2u) && loop_ui_score_click_ready()){
  score_mode=0;return 1;
 }
 return 0;
}
