#include "bt_score.h"
#include "audio_midi.h"
#include "console_ui.h"
uint32_t bt_hw_read(unsigned offset){__asm__ volatile("fence iorw,iorw":::"memory");return *(volatile uint32_t*)(uintptr_t)(0xf8000700u+offset);}
void bt_hw_write(unsigned offset,uint32_t value){*(volatile uint32_t*)(uintptr_t)(0xf8000700u+offset)=value;__asm__ volatile("fence iorw,iorw":::"memory");}
int bt_solo_enter(void){return console_score_begin();}
void bt_solo_leave(void){console_score_end();}
int bt_solo_restored(void){return console_score_restored();}
int bt_solo_stopped(void){return console_ui.stopped;}
int bt_solo_ready(void){return console_score_ready();}
void bt_audio_reset(void){audio_midi_reset_all();}
int bt_audio_event(uint32_t word){return audio_midi_send_word(word);}
