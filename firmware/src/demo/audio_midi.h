#ifndef AUDIO_MIDI_H
#define AUDIO_MIDI_H
#include <stdint.h>
int audio_midi_init(void);
void audio_midi_reset_all(void);
int audio_midi_send_word(uint32_t word);
void audio_midi_poll(void);
void audio_midi_disconnect(unsigned source);
extern volatile uint32_t audio_events_enqueued,audio_events_sent,audio_queue_overflows;
extern volatile uint32_t audio_fifo_rejections;
extern volatile uint32_t audio_ignored_messages,audio_hardware_present;
#endif
