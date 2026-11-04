#include "audio_midi.h"
#include "midi_router.h"
#define AUDIO_BASE 0xf8000200u
#define QUEUE_SIZE 512u
static uint32_t queue[QUEUE_SIZE];
static unsigned head,tail,panic_pending;
volatile uint32_t audio_events_enqueued,audio_events_sent,audio_queue_overflows;
volatile uint32_t audio_ignored_messages,audio_hardware_present;
#ifdef AUDIO_MIDI_HOST_TEST
extern uint32_t audio_test_read(unsigned offset);
extern void audio_test_write(unsigned offset,uint32_t value);
#define read_reg audio_test_read
#define write_reg audio_test_write
#else
static uint32_t read_reg(unsigned offset) {
    __asm__ volatile("fence iorw, iorw" ::: "memory");
    return *(volatile uint32_t *)(uintptr_t)(AUDIO_BASE+offset);
}
static void write_reg(unsigned offset,uint32_t value) {
    *(volatile uint32_t *)(uintptr_t)(AUDIO_BASE+offset)=value;
    __asm__ volatile("fence iorw, iorw" ::: "memory");
}
#endif
volatile uint32_t audio_fifo_rejections;
int audio_midi_init(void) {
    head=tail=0;panic_pending=3;
    audio_hardware_present=read_reg(0xf0)==0x4d410101u;
    return audio_hardware_present?0:-1;
}
void audio_midi_disconnect(unsigned source) {
    if(source>=1 && source<=2) {
        unsigned next=tail;
        /* Discard pending events from the ended session before its reset.
         * Single producer/consumer main loop; preserves the other port order. */
        for(unsigned i=tail;i!=head;++i) {
            uint32_t word=queue[i&(QUEUE_SIZE-1)];
            if(((word>>27)&1u)!=source-1u)queue[next++&(QUEUE_SIZE-1)]=word;
        }
        head=next;panic_pending|=1u<<(source-1);
    }
}
void midi_on_event(const sourced_midi_event *event) {
    const midi_event *m=&event->midi;
    unsigned status,kind;
    uint32_t word;
    if(event->synthetic) return; /* Explicit reset releases all source notes at once. */
    if(!audio_hardware_present || m->length!=3) {++audio_ignored_messages;return;}
    status=m->bytes[0]&0xf0u;
    if(status==0x90u)kind=m->bytes[2]?1u:2u;
    else if(status==0x80u)kind=2u;
    else {++audio_ignored_messages;return;}
    word=(kind<<28)|((uint32_t)(event->source_port==2)<<27)|
        ((uint32_t)m->cable<<23)|((uint32_t)(m->bytes[0]&15u)<<19);
    word|=((uint32_t)m->bytes[1]<<12)|m->bytes[2];
    if(head-tail==QUEUE_SIZE) {
        /* Never drop just a NoteOff and strand a voice. Drop pending history,
         * release both sources, then allow subsequent physical events. */
        tail=head;panic_pending=3;++audio_queue_overflows;
        return;
    }
    queue[head++&(QUEUE_SIZE-1)]=word;++audio_events_enqueued;
}
void audio_midi_poll(void) {
    unsigned budget=4;
    if(!audio_hardware_present)return;
    audio_fifo_rejections=read_reg(8);
    while(budget-- && (read_reg(4)&2u)) {
        if(panic_pending) {
            unsigned source=(panic_pending&1u)?0u:1u;
            write_reg(0,(4u<<28)|(source<<27));panic_pending&=~(1u<<source);
        } else if(tail!=head)write_reg(0,queue[tail++&(QUEUE_SIZE-1)]);
        else break;
        ++audio_events_sent;
    }
}

void audio_midi_reset_all(void){tail=head;panic_pending=3;}
int audio_midi_send_word(uint32_t word){
 if(!audio_hardware_present || head-tail==QUEUE_SIZE)return 0;
 queue[head++&(QUEUE_SIZE-1)]=word;++audio_events_enqueued;return 1;
}
