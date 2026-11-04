#include "midi_router.h"
#include <string.h>

void midi_router_init(midi_router *r, midi_router_sink sink, void *context)
{
    memset(r, 0, sizeof(*r));
    r->sink = sink;
    r->context = context;
}

const char *midi_source_name(unsigned source_port)
{
    return source_port == MIDI_SOURCE_KEYBOARD ? "KEYBOARD" :
           source_port == MIDI_SOURCE_DRUM ? "DRUM" : "UNKNOWN";
}

static void emit(midi_router *r, unsigned port, const midi_event *m, unsigned synthetic)
{
    sourced_midi_event event;
    event.source_port = (uint8_t)port;
    event.synthetic = (uint8_t)synthetic;
    event.midi = *m;
    if (r->sink) r->sink(r->context, &event);
}

int midi_router_deliver(midi_router *r, unsigned port, const midi_event *input)
{
    midi_event event;
    unsigned source;
    if (!r || !input || port < 1 || port > 2 || input->cable > 15 ||
        input->length < 1 || input->length > 3) return 0;
    source = port - 1;
    if (r->releasing[source]) {
        /* An unusually fast reattach must not mix new notes with old releases. */
        ++r->blocked_events;
        return 0;
    }
    event = *input;
    if (event.kind == MIDI_NOTE_ON || event.kind == MIDI_NOTE_OFF) {
        uint8_t *bits;
        unsigned note = event.bytes[1];
        if (event.channel < 1 || event.channel > 16 || event.length != 3 ||
            note > 127 || event.bytes[2] > 127) return 0;
        if (event.kind == MIDI_NOTE_ON && !event.bytes[2]) event.kind = MIDI_NOTE_OFF;
        bits = &r->active_notes[source][event.cable][event.channel - 1][note >> 3];
        if (event.kind == MIDI_NOTE_ON) *bits |= (uint8_t)(1u << (note & 7));
        else *bits &= (uint8_t)~(1u << (note & 7));
    }
    emit(r, port, &event, 0);
    return 1;
}

void midi_router_disconnect(midi_router *r, unsigned port)
{
    if (!r || port < 1 || port > 2) return;
    if (!r->releasing[port - 1]) {
        r->release_cursor[port - 1] = 0;
        r->releasing[port - 1] = 1;
    }
}

int midi_router_is_releasing(const midi_router *r, unsigned port)
{
    return r && port >= 1 && port <= 2 && r->releasing[port - 1];
}

void midi_router_step(midi_router *r)
{
    unsigned source;
    for (source = 0; source < 2; ++source) {
        unsigned budget = 32;
        if (!r->releasing[source]) continue;
        while (budget-- && r->release_cursor[source] < 32768u) {
            unsigned cursor = r->release_cursor[source]++;
            unsigned cable = cursor >> 11;
            unsigned channel = (cursor >> 7) & 15;
            unsigned note = cursor & 127;
            uint8_t *bits = &r->active_notes[source][cable][channel][note >> 3];
            if (*bits & (1u << (note & 7))) {
                midi_event event = {0};
                *bits &= (uint8_t)~(1u << (note & 7));
                event.kind = MIDI_NOTE_OFF;
                event.cable = (uint8_t)cable;
                event.channel = (uint8_t)(channel + 1);
                event.cin = 8;
                event.length = 3;
                event.bytes[0] = (uint8_t)(0x80 | channel);
                event.bytes[1] = (uint8_t)note;
                emit(r, source + 1, &event, 1);
                break;
            }
        }
        if (r->release_cursor[source] == 32768u) r->releasing[source] = 0;
    }
}
