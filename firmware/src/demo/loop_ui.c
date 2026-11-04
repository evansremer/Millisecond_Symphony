#include "loop_ui.h"
#include "bt_score.h"
#include <string.h>
loop_ui_state loop_ui;
static unsigned score_click_pending,score_click_desired;
#ifdef CONSOLE_HOST_TEST
/* Existing host console fixture does not emulate this new APB page. */
#ifdef LOOP_HOST_TEST
extern uint32_t loop_test_read(unsigned);
extern void loop_test_write(unsigned,uint32_t);
#define rr loop_test_read
#define wr loop_test_write
#else
static uint32_t rr(unsigned o){(void)o;return 0;}
static void wr(unsigned o,uint32_t v){(void)o;(void)v;}
#endif
#else
static uint32_t rr(unsigned o){__asm__ volatile("fence iorw,iorw":::"memory");return *(volatile uint32_t*)(uintptr_t)(0xf8000600u+o);}
static void wr(unsigned o,uint32_t v){*(volatile uint32_t*)(uintptr_t)(0xf8000600u+o)=v;__asm__ volatile("fence iorw,iorw":::"memory");}
#endif
static int hit(unsigned x,unsigned y,unsigned l,unsigned t,unsigned r,unsigned b){return x>=l&&x<r&&y>=t&&y<b;}
static unsigned clamp(int v,unsigned hi){return v<0?0:v>(int)hi?hi:(unsigned)v;}
static unsigned state(void){return loop_ui.status[0]&15u;}
static unsigned flags(void){return loop_ui.status[4];}
static int locked(void){return (loop_ui.status[0]&16u)||state()==1||state()==2||state()==3;}
int loop_ui_active(void){return state()==1||state()==2||state()==3||state()==4||(flags()&((1u<<4)|(1u<<7)));}
static int send_command(unsigned op,uint32_t p1,uint32_t p2,uint32_t p0)
{
 if(!loop_ui.present || (rr(4)&1u)){loop_ui.notice=1;return 0;}
 ++loop_ui.seq;
 wr(0x40,op|(p0&0xffffff00u));wr(0x44,p1);wr(0x48,p2);wr(0x4c,(uint32_t)loop_ui.seq<<16);wr(0x10,1);
 loop_ui.notice=0;return 1;
}
int loop_ui_send(unsigned op,uint32_t p1,uint32_t p2,uint32_t p0){
 if(bt_score_active() && op!=9 && op!=12)return 0;
 return send_command(op,p1,p2,p0);
}
void loop_ui_score_click(unsigned enabled){score_click_desired=enabled!=0;score_click_pending=1;}
int loop_ui_score_click_ready(void){return !score_click_pending && !(rr(4)&1u) && loop_ui.click==score_click_desired;}
static void config(void)
{
 uint32_t n=(48000u*60u*4u*loop_ui.bars+loop_ui.bpm/2u)/loop_ui.bpm;
 if(loop_ui_send(1,n,0,(uint32_t)loop_ui.bpm<<8|(uint32_t)loop_ui.bars<<16))loop_ui.parameter_pending=1;
 else loop_ui.parameter_pending=2;
}
static void gains(void){loop_ui.gains_dirty=1;}
static void snapshot(void){wr(0x20,1);for(unsigned i=0;i<16;++i){wr(0x24,i);loop_ui.status[i]=rr(0x28);}}
int loop_ui_score_available(void){
 if(!loop_ui.present || loop_ui.parameter_pending || (rr(4)&1u))return 0;
 snapshot();return !loop_ui_active() && !(rr(4)&1u);
}
static void tap(void)
{
 snapshot();
 uint64_t now=(uint64_t)loop_ui.status[5]|((uint64_t)loop_ui.status[6]<<32);
 unsigned count=loop_ui.tap_count;
 if(count && now-loop_ui.taps[count-1]>144000u)count=0;
 if(count && now-loop_ui.taps[count-1]<12000u){loop_ui.notice=2;return;}
 if(count==6){memmove(loop_ui.taps,loop_ui.taps+1,5*sizeof(uint64_t));count=5;}
 loop_ui.taps[count++]=now;loop_ui.tap_count=(uint8_t)count;
 if(count<3)return;
 uint32_t d[5];unsigned n=0;
 for(unsigned i=1;i<count;++i){uint64_t delta=loop_ui.taps[i]-loop_ui.taps[i-1];if(delta<12000u||delta>72000u){loop_ui.notice=2;return;}d[n++]=(uint32_t)delta;}
 for(unsigned i=1;i<n;++i)for(unsigned j=i;j>0&&d[j]<d[j-1];--j){uint32_t t=d[j];d[j]=d[j-1];d[j-1]=t;}
 uint32_t median=n&1u?d[n/2]:(d[n/2-1]+d[n/2])/2;
 loop_ui.bpm=(uint16_t)((2880000u+median/2)/median);config();
}
void loop_ui_init(void)
{memset(&loop_ui,0,sizeof loop_ui);score_click_pending=score_click_desired=0;loop_ui.bpm=120;loop_ui.bars=2;loop_ui.volume=50;loop_ui.click_volume=20;loop_ui.overdub_volume=100;loop_ui.present=rr(0)==0x4c500100u;}
void loop_ui_poll(uint32_t now)
{
 if(!loop_ui.present)return;
 if(!(rr(4)&1u)){
  if(score_click_pending){if(send_command(8,0,0,score_click_desired?256u:0u))score_click_pending=0;}
  else if(loop_ui.parameter_pending==2)config();
  else if(loop_ui.overdub_dirty && loop_ui_send(12,((uint32_t)loop_ui.overdub_volume*32768u+50u)/100u,0,0))loop_ui.overdub_dirty=0;
  else if(loop_ui.gains_dirty && loop_ui_send(9,((uint32_t)loop_ui.volume*65536u+50u)/100u,((uint32_t)loop_ui.click_volume*65536u+50u)/100u,0))loop_ui.gains_dirty=0;
 }
 if(loop_ui.modal && (int32_t)(now-loop_ui.modal_until)>=0)loop_ui.modal=0;
 if((int32_t)(now-loop_ui.refresh)<0)return;
 loop_ui.refresh=now+16;
 snapshot();
 loop_ui.click=(uint8_t)((flags()>>8)&1u);
 if(loop_ui.parameter_pending && loop_ui.status[2] && (loop_ui.status[1]&255u)==loop_ui.bpm && ((loop_ui.status[1]>>12)&15u)==loop_ui.bars)loop_ui.parameter_pending=0;
}
int loop_ui_press(unsigned x,unsigned y,unsigned page,unsigned stopped,unsigned test)
{
 loop_ui.capture=0;loop_ui.pressed=0;
 if(!loop_ui.present || bt_score_active())return 0;
 if(loop_ui.modal){
  if(hit(x,y,360,loop_ui.modal==2?352:256,672,loop_ui.modal==2?424:328)){loop_ui.modal=0;return 1;}
  if(loop_ui.modal==1 && hit(x,y,696,256,1040,328)){loop_ui_send(7,0,0,0);loop_ui.modal=0;return 1;}
  if(loop_ui.modal==2){
   if(hit(x,y,360,120,440,192)){loop_ui.overdub_volume=(uint16_t)clamp((int)loop_ui.overdub_volume-1,100);loop_ui.overdub_dirty=1;}
   else if(hit(x,y,1056,120,1136,192)){loop_ui.overdub_volume=(uint16_t)clamp((int)loop_ui.overdub_volume+1,100);loop_ui.overdub_dirty=1;}
   else if(hit(x,y,448,120,1048,192)){loop_ui.capture=3;loop_ui_move(x);}
   else if(hit(x,y,360,240,440,312)){loop_ui.click_volume=(uint16_t)clamp((int)loop_ui.click_volume-1,100);gains();}
   else if(hit(x,y,1056,240,1136,312)){loop_ui.click_volume=(uint16_t)clamp((int)loop_ui.click_volume+1,100);gains();}
   else if(hit(x,y,448,240,1048,312)){loop_ui.capture=2;loop_ui_move(x);}
   else if(hit(x,y,696,352,1040,424))loop_ui_send(10,0,0,0);
  }
  return 1;
 }
 if(page!=0 || y<280 || x>=1360)return 0;
 loop_ui.pressed=1;
 if(y>=360){
  static const unsigned right[]={176,352,528,704,848,992};
  static const unsigned left[]={8,184,360,536,712,856};
  for(unsigned i=0;i<6;++i)if(x>=left[i]&&x<right[i])loop_ui.pressed=(uint8_t)(i+2);
 }
 unsigned s=state();
 if(y<352){
  if(hit(x,y,976,280,1080,352)){loop_ui.modal=2;loop_ui.modal_until=loop_ui.refresh+30000u;return 1;}
  if(hit(x,y,856,280,968,352)){loop_ui_send(8,0,0,loop_ui.click?0:256u);return 1;}
  if(locked()){loop_ui.notice=3;return 1;}
  if(hit(x,y,8,280,88,352)){if(loop_ui.bpm>40)--loop_ui.bpm;config();}
  if(hit(x,y,208,280,288,352)){if(loop_ui.bpm<240)++loop_ui.bpm;config();}
  if(hit(x,y,296,280,400,352))tap();
  static const unsigned bars[]={1,2,4,8};
  for(unsigned i=0;i<4;++i)if(hit(x,y,408+i*112,280,512+i*112,352)){loop_ui.bars=(uint8_t)bars[i];config();}
  return 1;
 }
 if(hit(x,y,8,360,176,432)){if(!stopped&&!test)loop_ui_send(2,0,0,0);else loop_ui.notice=4;}
 else if(hit(x,y,184,360,352,432)){if(!stopped&&!test)loop_ui_send(3,0,0,0);else loop_ui.notice=4;}
 else if(hit(x,y,360,360,528,432)){if(!stopped&&!test)loop_ui_send(4,0,0,0);else loop_ui.notice=4;}
 else if(hit(x,y,536,360,704,432))loop_ui_send(5,0,0,0);
 else if(hit(x,y,712,360,848,432))loop_ui_send(6,0,0,0);
 else if(hit(x,y,856,360,992,432)){
  if(s==3 || (flags()&(1u<<2)) || (flags()&(1u<<7)))loop_ui.notice=5;
  else if(flags()&(1u<<6))loop_ui_send(7,0,0,0);
  else {loop_ui.modal=1;loop_ui.modal_until=loop_ui.refresh+10000u;}
 }
 else if(hit(x,y,1000,360,1080,432)){loop_ui.volume=(uint16_t)clamp((int)loop_ui.volume-1,100);gains();}
 else if(hit(x,y,1280,360,1360,432)){loop_ui.volume=(uint16_t)clamp((int)loop_ui.volume+1,100);gains();}
 else if(hit(x,y,1088,360,1272,432)){loop_ui.capture=1;loop_ui_move(x);}
 return 1;
}
void loop_ui_move(unsigned x)
{
 unsigned left=loop_ui.capture==1?1104:464,right=loop_ui.capture==1?1256:1032;
 if(!loop_ui.capture)return;
 unsigned v=x<=left?0:x>=right?100:((x-left)*100u+(right-left)/2)/(right-left);
 if(loop_ui.capture==3){loop_ui.overdub_volume=(uint16_t)v;loop_ui.overdub_dirty=1;}
 else {if(loop_ui.capture==1)loop_ui.volume=(uint16_t)v;else loop_ui.click_volume=(uint16_t)v;gains();}
}
void loop_ui_release(void){loop_ui.capture=0;loop_ui.pressed=0;}
void loop_ui_page_changed(void){loop_ui.modal=0;loop_ui_release();}
const char *loop_ui_press_name(void)
{
 static const char *names[]={"","TOUCH: LOOP CONTROL","TOUCH: RECORD","TOUCH: PLAY","TOUCH: OVERDUB","TOUCH: STOP","TOUCH: UNDO","TOUCH: CLEAR"};
 return names[loop_ui.pressed<8?loop_ui.pressed:0];
}
const char *loop_ui_state_name(void)
{
 if(!loop_ui.present)return "LOOP UNAVAILABLE";
 if(state()==6)return "DDR FAULT / LIVE OK";
 if(!(loop_ui.status[0]&32u))return "DDR WAIT / LIVE OK";
 if(state()==1)return "WAIT COUNT-IN";
 if(state()==2)return "COUNT-IN";
 if(state()==3)return "RECORDING";
 if(flags()&(1u<<6))return "WAIT CLEAR";
 if(flags()&(1u<<3))return "WAIT STOP";
 if(flags()&(1u<<2))return "OVERDUBBING";
 if(flags()&(1u<<1))return "WAIT OVERDUB";
 if(flags()&(1u<<5))return "WAIT UNDO";
 if(flags()&(1u<<4))return "WAIT PLAY";
 if(flags()&(1u<<7))return "VERIFY TAIL";
 return state()==4?"LOOP PLAYING":state()==5?"LOOP STOPPED":"EMPTY LOOP";
}
unsigned loop_ui_progress(void)
{return loop_ui.status[2]?(unsigned)(((uint64_t)loop_ui.status[3]*1000u)/loop_ui.status[2]):0;}
