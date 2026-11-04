#ifndef CONSOLE_UI_H
#define CONSOLE_UI_H
#include <stdint.h>
typedef struct {
 uint16_t adsr[4],gain[5]; /* dry,wet,width,master,pan */
 uint8_t instrument,waveform,eq,reverb;
 int8_t octave;
 uint8_t page,subpage[4],laser,mix,muted,stopped,test_count,freeze,zoom;
 uint8_t response,maintenance_confirm,calibration_stage,calibration_valid,test_load;
 uint16_t config_request,cursor;
 uint32_t audio[32],frames,heartbeat,touch_errors,fs_reference;
 uint32_t last_midi[2],last_velocity[2];
 uint16_t pending_near[2],pending_far[2];uint8_t pending_low,pending_high;
 int32_t cal_sx,cal_sy,cal_ox,cal_oy;
} console_ui_state;
extern console_ui_state console_ui;
int console_score_begin(void);
int console_score_ready(void);
void console_score_end(void);
int console_score_restored(void);
void console_ui_init(uint32_t now);
void console_ui_poll(uint32_t now,unsigned ready_mask,uint32_t input_errors);
void console_ui_midi(unsigned source,unsigned note,unsigned velocity);
#endif
