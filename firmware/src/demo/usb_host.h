#ifndef DUAL_MIDI_USB_HOST_H
#define DUAL_MIDI_USB_HOST_H
#include "usb_midi1.h"

enum { USB_NAK=-1, USB_TIMEOUT=-2, USB_STALL=-3, USB_PROTOCOL=-4,
       USB_OVERFLOW=-5, USB_DUPLICATE=-6, USB_HARDWARE=-7 };
typedef enum {
    USB_HOST_DETACHED, USB_HOST_DEBOUNCE, USB_HOST_RESET_ASSERT,
    USB_HOST_RESET_RECOVERY, USB_HOST_ENUMERATING, USB_HOST_READY,
    USB_HOST_RETRY_DELAY
} usb_host_state;
typedef struct {
    void *context;
    uint32_t (*read)(void *, unsigned);
    void (*write)(void *, unsigned, uint32_t);
    uint32_t (*now_ms)(void *);
} usb_host_io;

/* Statically allocate one instance for each physical controller. No globals,
 * dynamic allocations, sleeping, or interrupt handlers are used by the driver.
 */
typedef struct {
    usb_host_io io;
    usb_host_state state;
    uint8_t packet[64];
    uint16_t vid, pid;
    usb_midi1_endpoint midi;
    uint32_t generation, errors;
    int last_error;

    /* Driver-private state. Exposed only to permit static allocation. */
    uint32_t control, deadline, next_poll, transfer_at, retry_at, retry_until;
    uint32_t se0_at, idle_wait_at;
    uint8_t address, ep0_size, input_toggle, consecutive_errors;
    uint8_t se0_seen, transfer_active, idle_waiting, transfer_input;
    uint8_t transfer_toggle, enum_stage, control_active, control_phase, discard_rx;
    uint8_t control_read, control_toggle, setup[8], device[18], config_index;
    uint16_t control_length, control_done, config_length;
    uint8_t *control_buffer;
    uint8_t descriptor[1024];

    /* Observability only: never changes retries or packet acceptance. */
    uint32_t hw_timeouts, crc_errors, phy_errors, sw_timeouts, nak_count;
    uint32_t error_rx_status, error_bus_status;
} usb_host;

/* Verifies the dual-port FPGA ID and port count, then leaves SOF disabled.
 * Does not reset the CPU, the other USB controller, or the FPGA.
 */
int usb_host_init(usb_host *, const usb_host_io *);
/* Bounded cooperative step: starts at most one USB transaction OR processes
 * one completion. Positive result: new MIDI packet bytes in packet[]. Zero:
 * no new packet. READY transitions never return a packet in the same step.
 * Inspect state/generation for attachment changes and errors/last_error for
 * failures. NAK and already-ACKed duplicate data are not delivered or errors.
 */
int usb_host_step(usb_host *);
unsigned usb_host_line(usb_host *);
#endif
