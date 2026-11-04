#include "usb_midi1.h"

int usb_midi1_decode(const uint8_t p[4], midi_event *e)
{
    static const uint8_t lengths[16] = {0,0,2,3,3,1,2,3,3,3,3,3,2,2,3,1};
    uint8_t cin, i, status;
    midi_event out = {0};
    if (!p || !e) return 0;
    cin = p[0] & 15;
    if (!lengths[cin]) return 0;
    out.cable = p[0] >> 4;
    out.cin = cin;
    out.length = lengths[cin];
    for (i = 0; i < out.length; ++i) out.bytes[i] = p[i+1];
    status = p[1];
    if (cin >= 8 && cin <= 14) {
        if ((status >> 4) != cin) return 0;
        for (i = 1; i < out.length; ++i)
            if (out.bytes[i] & 0x80) return 0;
        out.channel = (status & 15) + 1;
        switch (cin) {
        case 8: out.kind = MIDI_NOTE_OFF; break;
        case 9: out.kind = p[3] ? MIDI_NOTE_ON : MIDI_NOTE_OFF; break;
        case 10: out.kind = MIDI_POLY_PRESSURE; break;
        case 11: out.kind = MIDI_CONTROL_CHANGE; break;
        case 12: out.kind = MIDI_PROGRAM_CHANGE; break;
        case 13: out.kind = MIDI_CHANNEL_PRESSURE; break;
        case 14:
            out.kind = MIDI_PITCH_BEND;
            out.value = (uint16_t)p[2] | ((uint16_t)p[3] << 7);
            break;
        }
    } else if (cin == 2 || cin == 3) {
        if (cin == 2 && status != 0xF1 && status != 0xF3) return 0;
        if (cin == 3 && status != 0xF2) return 0;
        for (i = 1; i < out.length; ++i)
            if (out.bytes[i] & 0x80) return 0;
        out.kind = MIDI_SYSTEM;
    } else if (cin == 5 && status == 0xF6) {
        out.kind = MIDI_SYSTEM;
    } else if (cin >= 4 && cin <= 7) {
        uint8_t end = cin == 4 ? out.length : out.length - 1;
        if (cin != 4 && out.bytes[out.length-1] != 0xF7) return 0;
        for (i = 0; i < end; ++i)
            if ((out.bytes[i] & 0x80) && !(i == 0 && out.bytes[i] == 0xF0))
                return 0;
        out.kind = MIDI_SYSEX_FRAGMENT;
    } else {
        out.kind = MIDI_SINGLE_BYTE;
    }
    *e = out;
    return 1;
}

int usb_midi1_find_in(const uint8_t *d, size_t n, usb_midi1_endpoint *e)
{
    size_t offset, total;
    int selected = 0, found = 0;
    uint8_t interface_number = 0;
    usb_midi1_endpoint candidate = {0};
    if (!d || !e || n < 9 || d[0] < 9 || d[1] != 2) return -1;
    total = (size_t)d[2] | ((size_t)d[3] << 8);
    if (total < d[0] || total > n || !d[5]) return -1;
    for (offset = d[0]; offset < total; offset += d[offset]) {
        uint8_t len, type;
        if (total - offset < 2) return -1;
        len = d[offset];
        type = d[offset+1];
        if (len < 2 || len > total - offset) return -1;
        if (type == 4) {
            if (len < 9) return -1;
            /* Audio class, MIDIStreaming subclass, MIDI 1.0, alternate 0. */
            selected = d[offset+3] == 0 && d[offset+5] == 1 &&
                       d[offset+6] == 3 && d[offset+7] == 0;
            interface_number = d[offset+2];
        } else if (type == 5) {
            uint8_t addr;
            uint16_t size;
            if (len < 7) return -1;
            addr = d[offset+2];
            size = (uint16_t)d[offset+4] | ((uint16_t)d[offset+5] << 8);
            if (selected && !found && (addr & 0x80) && (addr & 15) &&
                !(addr & 0x70) && (d[offset+3] & 3) == 2 && size &&
                !(size & 0xF800)) {
                candidate.configuration = d[5];
                candidate.interface_number = interface_number;
                candidate.alternate_setting = 0;
                candidate.endpoint_in = addr;
                candidate.max_packet_size = size;
                found = 1;
            }
        }
    }
    if (found) *e = candidate;
    return found;
}
