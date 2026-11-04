#ifndef BT_SCORE_H
#define BT_SCORE_H
#include <stdint.h>
enum {BT_IDLE,BT_BUFFERING,BT_ARMING,BT_PLAYING,BT_DRAINING,BT_FAULT};
enum {BT_OK,BT_BAD_FRAME,BT_SEQUENCE,BT_CAPACITY,BT_BUSY,BT_UNDERRUN,BT_TIMEOUT,BT_UART_ERROR,BT_AUDIO_ERROR,BT_GLOBAL_STOP,BT_STOPPED,BT_FINISHED,BT_NOT_READY};
typedef struct {
 uint32_t state,reason,session,expected,queued,free_slots,position_ms,buffered_ms;
 uint32_t events_sent,crc_errors,sequence_errors,max_late_us,uart_errors,present;
} bt_score_status;
extern volatile bt_score_status bt_status;
void bt_score_init(void);
int bt_router_memory_check(void);
void bt_score_poll(uint64_t now_us);
void bt_score_cancel(unsigned reason);
int bt_score_active(void);
const char *bt_score_name(void);
/* Platform hooks. Bounded/nonblocking; tested with a simulated UART/audio sink. */
uint32_t bt_hw_read(unsigned offset);
void bt_hw_write(unsigned offset,uint32_t value);
int bt_solo_enter(void);
void bt_solo_leave(void);
int bt_solo_restored(void);
int bt_solo_stopped(void);
int bt_solo_ready(void);
void bt_audio_reset(void);
int bt_audio_event(uint32_t word);
#endif
