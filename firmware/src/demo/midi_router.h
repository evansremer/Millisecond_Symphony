#ifndef DUAL_USB_MIDI_ROUTER_H
#define DUAL_USB_MIDI_ROUTER_H

#include "usb_midi1.h"

enum { MIDI_SOURCE_KEYBOARD = 1, MIDI_SOURCE_DRUM = 2, MIDI_SOURCE_COUNT = 2 };

typedef struct {
    uint8_t source_port;  /* Physical USB socket, 1=keyboard, 2=drum. */
    uint8_t synthetic;    /* 1 for a Note Off generated during disconnect. */
    midi_event midi;      /* Original USB cable, MIDI channel and bytes. */
} sourced_midi_event;

/* The callback must return promptly: no UART waits, sleeping or USB operations.
 * The event pointer is valid only during the callback; copy the value to queue it.
 */
typedef void (*midi_router_sink)(void *context, const sourced_midi_event *event);

typedef struct {
    uint8_t active_notes[2][16][16][16];
    uint16_t release_cursor[2];
    uint8_t releasing[2];
    uint32_t blocked_events;
    midi_router_sink sink;
    void *context;
} midi_router;

void midi_router_init(midi_router *, midi_router_sink, void *context);
const char *midi_source_name(unsigned source_port);
/* Returns 1 if accepted, 0 for an invalid source/event or a releasing source. */
int midi_router_deliver(midi_router *, unsigned source_port, const midi_event *);
void midi_router_disconnect(midi_router *, unsigned source_port);
/* Bounded work: each source scans <=32 note slots and emits <=1 release event.
 * Call every main-loop iteration, even if no USB packets are received.
 */
void midi_router_step(midi_router *);
int midi_router_is_releasing(const midi_router *, unsigned source_port);

/* main.c supplies a weak implementation that queues a source-labelled log.
 * Override this in an application source file; return promptly, with no waits.
 */
void midi_on_event(const sourced_midi_event *);

#endif
