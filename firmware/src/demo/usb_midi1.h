#ifndef USB_MIDI1_H
#define USB_MIDI1_H
#include <stddef.h>
#include <stdint.h>

typedef enum {
    MIDI_SYSTEM, MIDI_SYSEX_FRAGMENT, MIDI_NOTE_OFF, MIDI_NOTE_ON,
    MIDI_POLY_PRESSURE, MIDI_CONTROL_CHANGE, MIDI_PROGRAM_CHANGE,
    MIDI_CHANNEL_PRESSURE, MIDI_PITCH_BEND, MIDI_SINGLE_BYTE
} midi_kind;

typedef struct {
    midi_kind kind;
    uint8_t cable;       /* USB virtual cable 0..15 */
    uint8_t cin;
    uint8_t channel;     /* 1..16 for channel messages; 0 otherwise */
    uint8_t length;
    uint8_t bytes[3];    /* Original MIDI bytes, excluding USB packet header */
    uint16_t value;      /* Pitch bend 0..16383, centred at 8192 */
} midi_event;

/* Returns 1 for a decoded USB MIDI 1.0 event, 0 for an invalid/reserved packet.
 * SysEx is delivered in fragments; this function does not assemble a message.
 * CIN 0xF delivers a raw single byte; a MIDI stream parser may be needed.
 */
int usb_midi1_decode(const uint8_t packet[4], midi_event *event);

typedef struct {
    uint8_t configuration;
    uint8_t interface_number;
    uint8_t alternate_setting;
    uint8_t endpoint_in;
    uint16_t max_packet_size;
} usb_midi1_endpoint;

/* Examines a complete configuration descriptor returned by GET_DESCRIPTOR.
 * Returns 1 for MIDI 1.0 / default alternate / bulk IN, 0 for no match,
 * -1 for malformed/truncated descriptors. Does not perform USB enumeration.
 */
int usb_midi1_find_in(const uint8_t *data, size_t length,
                      usb_midi1_endpoint *endpoint);
#endif
