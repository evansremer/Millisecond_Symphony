#ifndef LOOP_UI_H
#define LOOP_UI_H
#include <stdint.h>
typedef struct {
 uint32_t status[16];
 uint16_t bpm,volume,click_volume,seq,overdub_volume;
 uint8_t bars,present,modal,capture,click,notice,parameter_pending,gains_dirty,pressed,overdub_dirty;
 uint64_t taps[6];uint8_t tap_count;
 uint32_t refresh,modal_until;
} loop_ui_state;
extern loop_ui_state loop_ui;
void loop_ui_init(void);
void loop_ui_poll(uint32_t now);
int loop_ui_press(unsigned x,unsigned y,unsigned page,unsigned stopped,unsigned test);
void loop_ui_move(unsigned x);
void loop_ui_release(void);
void loop_ui_page_changed(void);
int loop_ui_active(void);
int loop_ui_score_available(void);
void loop_ui_score_click(unsigned enabled);
int loop_ui_score_click_ready(void);
const char *loop_ui_state_name(void);
const char *loop_ui_press_name(void);
unsigned loop_ui_progress(void);
int loop_ui_send(unsigned op,uint32_t p1,uint32_t p2,uint32_t p0);
#endif
