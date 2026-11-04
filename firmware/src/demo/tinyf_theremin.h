#ifndef TINYF_THEREMIN_H
#define TINYF_THEREMIN_H
#include <stdint.h>

/* Independent control mailbox; never consumes MIDI FIFO entries. */
#define TINYF_BASE 0xf8000300u
#define TINYF_ID 0x54480101u
#define TINYF_ID_REG 0x00u
#define TINYF_UI_REG 0x04u
#define TINYF_ROUTE_REG 0x08u
#define TINYF_STEP_REG 0x0cu
#define TINYF_GAIN_REG 0x10u
#define TINYF_MIX_REG 0x14u
#define TINYF_COMMIT_REG 0x18u
#define TINYF_BUSY_REG 0x1cu
#define TINYF_FEEDBACK_REG 0x20u
/* Feedback: bit0 present, bit1 enabled, bit2 playing, bit3 configuring,
 * bit4/5 fresh pitch/volume, bit6 TX stalled, [9:8]/[11:10] rate result:
 * 0=not measured/other, 1=30 Hz, 2=60 Hz, 3=90 Hz. Actual millihertz
 * and no-data outcomes remain available in tinyf_diagnostics. */
#define TINYF_SAMPLE_RATE_NUM 11328125u
#define TINYF_SAMPLE_RATE_DEN 236u
#ifndef TINYF_MIN_CONFIDENCE
#define TINYF_MIN_CONFIDENCE 1u /* No manufacturer threshold; positive only. */
void tinyf_theremin_console_control(unsigned enabled,unsigned mix,unsigned request);
#endif
/* 2025 manual specifies 0..62. Captured installed modules output ASCII 100:
 * evidence/tinyf_raw_protocol_variant.json. Accept that observed variant up
 * to 100, without changing the distance unit or relaxing frame syntax. */
#define TINYF_MAX_CONFIDENCE 100u

typedef struct {
    uint32_t bytes, frames, valid_frames, rejected, uart_errors;
    uint32_t last_valid_ms, last_frame_ms, measured_millihz;
    uint32_t rate_start_ms, rate_frames;
    uint16_t distance_mm, target_mm;
    uint8_t confidence, have_valid, recovery_frames, rate_result;
    char line[12];
    uint8_t length, discard;
} tinyf_sensor;
typedef struct {
    tinyf_sensor sensor[2]; /* 0 UART1 pitch; 1 UART2 volume. */
    uint32_t step, gain, mix, commits, busy_polls, config_requests;
    uint32_t last_update_ms, config_start_ms;
    uint16_t seen_request;
    uint8_t present, enabled, playing, mix_percent;
    uint8_t config_phase, tx_index[2], tx_stalled;
    uint8_t dirty;
} tinyf_status;
extern tinyf_status tinyf_diagnostics;
/* Passive debugger capture: monotonically wrapping byte count; newest byte is
 * tinyf_raw[port][(tinyf_raw_head[port]-1)&63]. No extra UART FIFO reads. */
#define TINYF_RAW_SIZE 64u
extern volatile uint8_t tinyf_raw[2][TINYF_RAW_SIZE];
extern volatile uint32_t tinyf_raw_head[2];
int tinyf_theremin_init(uint32_t now_ms);
void tinyf_theremin_poll(uint32_t now_ms);
int tinyf_theremin_log_paused(void);
/* UART2 THRE query that preserves read-to-clear RX error status. All main-loop
 * logging must use this instead of reading UART2 LSR directly. */
int tinyf_theremin_log_ready(void);
/* Pure mapping exposed for numeric regression and debugger inspection. */
uint32_t tinyf_theremin_pitch_step(unsigned distance_mm);
uint32_t tinyf_theremin_volume(unsigned distance_mm);
int tinyf_theremin_set_mapping(const uint16_t near_mm[2],const uint16_t far_mm[2],unsigned low_note,unsigned high_note,unsigned smoothing_ms);
unsigned tinyf_theremin_pitch_position(uint32_t step);
unsigned tinyf_theremin_mapping(unsigned field);
void tinyf_theremin_console_control(unsigned enabled,unsigned mix,unsigned request);
#endif
