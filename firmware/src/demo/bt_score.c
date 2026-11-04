#include "bt_score.h"
#include <string.h>
#define CAP 1024u
#define PAYLOAD 192u
typedef struct {uint32_t time,word;} score_event;
#ifdef BT_HOST_TEST
static score_event events[CAP];
#else
static volatile score_event events[CAP] __attribute__((section(".bt_events"),aligned(8)));
#endif
volatile bt_score_status bt_status;
static uint8_t rx[206],tx[78];
static unsigned rn,need,tn,tp,head,tail,eof,solo,want_status,restoring;
static uint64_t clock_us,start_us,last_rx,last_byte,last_status,covered,received,drain_until;
static uint32_t last_seq,last_crc,uart_error;
static uint16_t rd16(const uint8_t *p){return (uint16_t)(p[0]|p[1]<<8);}
static uint32_t rd32(const uint8_t *p){return (uint32_t)rd16(p)|(uint32_t)rd16(p+2)<<16;}
static uint64_t rd64(const uint8_t *p){return rd32(p)|(uint64_t)rd32(p+4)<<32;}
static void wr16(uint8_t *p,unsigned v){p[0]=(uint8_t)v;p[1]=(uint8_t)(v>>8);}
static void wr32(uint8_t *p,uint32_t v){wr16(p,v);wr16(p+2,v>>16);}
static uint16_t crc16(const uint8_t *p,unsigned n){unsigned c=0xffff;while(n--){c^=(unsigned)*p++<<8;for(unsigned i=0;i<8;++i)c=c&0x8000?(c<<1)^0x1021:c<<1;}return (uint16_t)c;}
int bt_score_active(void){return solo!=0;}
const char *bt_score_name(void){static const char *n[]={"BT IDLE","BT BUFFER","BT PREPARE","BT PLAY","BT STOPPING","BT FAULT"};return n[bt_status.state<=BT_FAULT?bt_status.state:BT_FAULT];}
static void status(void)
{
 if(tp!=tn){want_status=1;return;} /* Never interleave two protocol frames. */
 want_status=0;
 bt_status.queued=head-tail;bt_status.free_slots=CAP-(head-tail);
 bt_status.buffered_ms=covered/1000u;
 tx[0]='B';tx[1]='T';tx[2]=1;tx[3]=0x80;wr32(tx+4,bt_status.session);
 wr16(tx+8,bt_status.expected);wr16(tx+10,60);
 const uint32_t fields[]={bt_status.state,bt_status.reason,bt_status.expected,bt_status.free_slots,
  bt_status.position_ms,(uint32_t)covered,(uint32_t)(covered>>32),bt_status.events_sent,
  bt_status.crc_errors,bt_status.sequence_errors,bt_status.max_late_us,bt_status.uart_errors,
  bt_status.present,head-tail,eof};
 for(unsigned i=0;i<15;++i)wr32(tx+12+4*i,fields[i]);
 wr16(tx+72,crc16(tx,72));tn=74;tp=0;last_status=clock_us;
}
void bt_score_cancel(unsigned reason)
{
 if(bt_status.state==BT_DRAINING)return;
 bt_status.reason=reason;head=tail=0;covered=received=0;eof=0;
 if(solo){bt_audio_reset();restoring=0;drain_until=clock_us+15000u;bt_status.state=BT_DRAINING;}
 else bt_status.state=(reason==BT_STOPPED || reason==BT_FINISHED)?BT_IDLE:BT_FAULT;
}
static int valid_word(uint32_t w)
{
 unsigned kind=w>>28,note=(w>>12)&127u,vel=w&127u;
 return (kind==1 || kind==2) && (w&0x07800f80u)==0 && note<=127u && vel<=127u;
}
static unsigned command(unsigned type,const uint8_t *p,unsigned n)
{
 if(type==2){
  if((bt_status.state!=BT_BUFFERING && bt_status.state!=BT_ARMING && bt_status.state!=BT_PLAYING) || n<12 || (n-12)%8 || eof)return BT_BAD_FRAME;
  unsigned count=(n-12)/8;uint64_t end=rd64(p),at=covered,previous=received;
  uint64_t pos=bt_status.state==BT_PLAYING?clock_us-start_us:0;
  if(count>CAP-(head-tail))return BT_CAPACITY;
  if((rd32(p+8)&~1u) || end<covered || end>pos+4000000u)return BT_BAD_FRAME;
  for(unsigned i=0;i<count;++i){at=covered+(uint32_t)(rd32(p+12+i*8)-(uint32_t)covered);if(at<previous || !valid_word(rd32(p+16+i*8)) || at>end || at<covered)return BT_BAD_FRAME;previous=at;}
  at=covered;
  for(unsigned i=0;i<count;++i){at=covered+(uint32_t)(rd32(p+12+i*8)-(uint32_t)covered);events[head++&(CAP-1)]=(score_event){(uint32_t)at,rd32(p+16+i*8)};}
  if(count){received=at;}covered=end;eof=rd32(p+8)&1u;return BT_OK;
 }
 if(type==3){
  if(n || bt_status.state!=BT_BUFFERING)return BT_BAD_FRAME;
  if(covered<2000000u && !eof)return BT_NOT_READY;
  if(!bt_solo_enter())return BT_BUSY;
  solo=1;bt_audio_reset();start_us=clock_us+50000u;bt_status.state=BT_ARMING;return BT_OK;
 }
 if(type==4){if(n)return BT_BAD_FRAME;bt_score_cancel(BT_STOPPED);return BT_OK;}
 if(type==5)return n?BT_BAD_FRAME:BT_OK;
 return BT_BAD_FRAME;
}
static void frame(void)
{
 unsigned n=rd16(rx+10),seq=rd16(rx+8),type=rx[3];
 uint32_t session=rd32(rx+4);unsigned c=rd16(rx+12+n);
 if(crc16(rx,12+n)!=c){++bt_status.crc_errors;return;}
 if(rx[2]!=1 || !session){bt_status.reason=BT_BAD_FRAME;return;}
 if(type==1 && seq==0 && n==0){
  if(bt_status.state==BT_FAULT && bt_status.reason==BT_NOT_READY){bt_status.session=session;bt_status.expected=0;status();return;}
  if(session!=bt_status.session){
   if(solo){bt_score_cancel(BT_STOPPED);return;}
   head=tail=0;covered=received=0;eof=0;
   bt_status.session=session;bt_status.expected=1;bt_status.state=BT_BUFFERING;
   bt_status.reason=BT_OK;bt_status.position_ms=0;bt_status.events_sent=bt_status.max_late_us=0;last_seq=0;last_crc=c;
  }
  last_rx=clock_us;status();return;
 }
 if(session!=bt_status.session)return;
 if(seq==last_seq && c==last_crc){last_rx=clock_us;status();return;}
 if(seq!=bt_status.expected){++bt_status.sequence_errors;bt_status.reason=BT_SEQUENCE;status();return;}
 unsigned result=command(type,rx+12,n);
 if(result!=BT_OK){bt_status.reason=result;status();return;}
 last_seq=seq;last_crc=c;bt_status.expected=(seq+1u)&65535u;
 last_rx=clock_us;
 if(bt_status.state!=BT_DRAINING)bt_status.reason=BT_OK;
 status();
}
static void feed(uint8_t b)
{
 if(rn==0){if(b=='B')rx[rn++]=b;return;}
 if(rn==1 && b!='T'){rn=b=='B'?1:0;return;}
 rx[rn++]=b;
 if(rn==12){unsigned n=rd16(rx+10);if(n>PAYLOAD){rn=0;++bt_status.crc_errors;return;}need=14+n;}
 if(rn>=12 && rn==need){frame();rn=0;}
}
void bt_score_init(void)
{
 memset((void*)&bt_status,0,sizeof bt_status);head=tail=rn=tn=tp=solo=eof=want_status=restoring=0;
 covered=received=clock_us=last_rx=last_status=0;need=0;last_seq=last_crc=0;
 bt_status.free_slots=CAP;
 if(!bt_router_memory_check()){bt_status.reason=BT_NOT_READY;bt_status.state=BT_FAULT;}
#ifndef BT_HOST_TEST
 for(unsigned i=0;i<CAP;++i)events[i]=(score_event){0x5a5a0000u^i,0xa5a50000u^i};
 for(unsigned i=0;i<CAP;++i)if(events[i].time!=(0x5a5a0000u^i) || events[i].word!=(0xa5a50000u^i)){bt_status.reason=BT_NOT_READY;bt_status.state=BT_FAULT;break;}
 memset((void*)events,0,sizeof events);
#endif
 bt_status.present=bt_hw_read(0xf0)==0x42540100u;
 uart_error=bt_hw_read(8)+bt_hw_read(12);
}
void bt_score_poll(uint64_t now_us)
{
 clock_us=now_us;if(!bt_status.present)return;
 unsigned err=bt_hw_read(8)+bt_hw_read(12);
 if(err!=uart_error){bt_status.uart_errors+=err-uart_error;uart_error=err;rn=0;if(solo)bt_score_cancel(BT_UART_ERROR);}
 if(rn && clock_us-last_byte>250000u)rn=0;
 for(unsigned i=0;i<64 && (bt_hw_read(4)&1u);++i){feed((uint8_t)bt_hw_read(0));last_byte=clock_us;}
 if(solo && bt_solo_stopped() && bt_status.state!=BT_DRAINING)bt_score_cancel(BT_GLOBAL_STOP);
 if(bt_status.state==BT_ARMING && clock_us>=start_us && bt_solo_ready()){
  start_us=clock_us;bt_status.state=BT_PLAYING;
 }
 if((bt_status.state==BT_ARMING || bt_status.state==BT_PLAYING || bt_status.state==BT_BUFFERING) && clock_us-last_rx>1000000u)bt_score_cancel(BT_TIMEOUT);
 if(bt_status.state==BT_PLAYING){
  uint64_t pos=clock_us-start_us;bt_status.position_ms=pos/1000u;
  for(unsigned i=0;i<32 && tail!=head;++i){
   score_event e=events[tail&(CAP-1)];int32_t late=(int32_t)((uint32_t)pos-e.time);
   if(late<0)break;
   if(!bt_audio_event(e.word)){bt_score_cancel(BT_AUDIO_ERROR);break;}
   if((unsigned)late>bt_status.max_late_us)bt_status.max_late_us=(unsigned)late;
   ++tail;++bt_status.events_sent;
  }
  if(bt_status.state==BT_PLAYING && pos>=covered){
   if(eof && tail==head)bt_score_cancel(BT_FINISHED);
   else if(!eof)bt_score_cancel(BT_UNDERRUN);
  }
 }
 if(bt_status.state==BT_DRAINING && clock_us>=drain_until){
  if(!restoring){bt_solo_leave();restoring=1;}
  if(bt_solo_restored()){solo=0;bt_status.state=(bt_status.reason==BT_STOPPED || bt_status.reason==BT_FINISHED || bt_status.reason==BT_GLOBAL_STOP)?BT_IDLE:BT_FAULT;}
 }
 if(clock_us-last_status>=100000u)status();
 for(unsigned i=0;i<16 && tp<tn && (bt_hw_read(4)&2u);++i)bt_hw_write(0,tx[tp++]);
 if(want_status && tp==tn)status();
 bt_status.queued=head-tail;bt_status.free_slots=CAP-(head-tail);
}
