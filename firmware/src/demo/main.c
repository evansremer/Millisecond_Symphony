#include "usb_host.h"
#include "audio_midi.h"
#include "bt_score.h"
#include "console_ui.h"
#include "loop_ui.h"
#include "tinyf_theremin.h"
#include "midi_router.h"
#include "uart.h"
#include "platform.h"
#include <stdint.h>

typedef struct { uintptr_t base; } usb_mmio_context;
static usb_mmio_context usb_contexts[2] = {{0xf8000000u}, {0xf8000100u}};
static usb_host hosts[2];
static midi_router router __attribute__((section(".bt_router"),aligned(8)));
volatile uint32_t midi_events_received[2], midi_synthetic_releases[2];
volatile uint32_t usb_errors[2], midi_decode_rejected[2], midi_backpressure_loops[2];
volatile uint32_t midi_log_dropped_lines;
volatile uint32_t midi_main_iterations;
volatile uint32_t console_poll_max_cycles,main_loop_max_cycles;
static uint32_t cycle_low(void){uint32_t value;__asm__ volatile("csrr %0, mcycle":"=r"(value));return value;}
int bt_router_memory_check(void)
{
    volatile uint32_t *words=(volatile uint32_t *)&router;
    const unsigned count=sizeof(router)/sizeof(uint32_t);
    for(unsigned i=0;i<count;++i)words[i]=0xa55a0000u^i;
    unsigned ok=1;
    for(unsigned i=0;i<count;++i)if(words[i]!=(0xa55a0000u^i)){ok=0;break;}
    for(unsigned i=0;i<count;++i)words[i]=0;
    return (int)ok;
}

static uint32_t reg_read(void *context, unsigned offset)
{
    usb_mmio_context *mmio = (usb_mmio_context *)context;
    __asm__ volatile("fence iorw, iorw" ::: "memory");
    return *(volatile uint32_t *)(mmio->base + offset);
}
static void reg_write(void *context, unsigned offset, uint32_t value)
{
    usb_mmio_context *mmio = (usb_mmio_context *)context;
    *(volatile uint32_t *)(mmio->base + offset) = value;
    __asm__ volatile("fence iorw, iorw" ::: "memory");
}
static uint64_t microseconds(void){
 uint32_t hi,lo,h2;do{__asm__ volatile("csrr %0,mcycleh":"=r"(hi));__asm__ volatile("csrr %0,mcycle":"=r"(lo));__asm__ volatile("csrr %0,mcycleh":"=r"(h2));}while(hi!=h2);
 return (((uint64_t)hi<<32)|lo)/800u;
}
static uint32_t millis(void *context)
{
    uint32_t hi, lo, hi2;
    (void)context;
    do {
        __asm__ volatile("csrr %0, mcycleh" : "=r"(hi));
        __asm__ volatile("csrr %0, mcycle" : "=r"(lo));
        __asm__ volatile("csrr %0, mcycleh" : "=r"(hi2));
    } while (hi != hi2);
    return (uint32_t)((((uint64_t)hi << 32) | lo) / 800000u);
}

/* Single main-loop producer/consumer. Reserve an entire line before copying;
 * overflow loses one complete log record, never half of a MIDI message.
 */
#define LOG_SIZE 2048u
static char log_buffer[LOG_SIZE];
static unsigned log_head, log_tail;
typedef struct { char bytes[128]; unsigned length; } log_line;
static void line_char(log_line *line, char ch)
{
    if (line->length < sizeof(line->bytes)) line->bytes[line->length] = ch;
    ++line->length;
}
static void line_text(log_line *line, const char *text)
{
    while (*text) line_char(line, *text++);
}
static void line_hex(log_line *line, unsigned value, unsigned digits)
{
    const char chars[] = "0123456789ABCDEF";
    while (digits) line_char(line, chars[(value >> (4 * --digits)) & 15]);
}
static void line_decimal(log_line *line, unsigned value)
{
    char digits[10];
    unsigned count = 0;
    do { digits[count++] = (char)('0' + value % 10u); value /= 10u; } while (value);
    while (count) line_char(line, digits[--count]);
}
static void line_source(log_line *line, unsigned port)
{
    line_text(line, "USB"); line_char(line, (char)('0' + port));
    line_char(line, ' '); line_text(line, midi_source_name(port));
}
static void line_commit(log_line *line)
{
    unsigned i, free_bytes = (log_tail - log_head - 1u) & (LOG_SIZE - 1u);
    line_text(line, "\r\n");
    if (line->length > sizeof(line->bytes) || line->length > free_bytes) {
        ++midi_log_dropped_lines;
        return;
    }
    for (i = 0; i < line->length; ++i)
        log_buffer[(log_head + i) & (LOG_SIZE - 1u)] = line->bytes[i];
    log_head = (log_head + line->length) & (LOG_SIZE - 1u);
}
static void log_message(const char *message)
{
    log_line line = {{0}, 0};
    line_text(&line, message); line_commit(&line);
}
static void log_drain(void)
{
    unsigned budget = 4;
    if (tinyf_theremin_log_paused()) return;
    while (budget-- && log_tail != log_head && tinyf_theremin_log_ready()) {
        DEV_UART2->THR = (unsigned char)log_buffer[log_tail];
        log_tail = (log_tail + 1u) & (LOG_SIZE - 1u);
    }
}

/* Application hook. Keep work bounded: enqueue an audio event and return.
 * USB host progress shares this main loop; do not wait for UART or audio here.
 * SysEx/raw CIN-F bytes remain fragments; no CH345 compatibility is implied.
 */
__attribute__((weak)) void midi_on_event(const sourced_midi_event *event)
{
    const midi_event *m = &event->midi;
    log_line line = {{0}, 0};
    unsigned i;
    line_source(&line, event->source_port); line_text(&line, " M ");
    line_hex(&line, m->cable, 1);
    for (i = 0; i < m->length; ++i) {
        line_char(&line, ' '); line_hex(&line, m->bytes[i], 2);
    }
    if (m->length == 3 && ((m->bytes[0] & 0xf0) == 0x90 ||
                           (m->bytes[0] & 0xf0) == 0x80)) {
        line_text(&line, ((m->bytes[0] & 0xf0) == 0x90 && m->bytes[2]) ?
                         " NoteOn ch=" : " NoteOff ch=");
        line_decimal(&line, (m->bytes[0] & 15u) + 1u);
        line_text(&line, " note="); line_decimal(&line, m->bytes[1]);
        line_text(&line, " velocity="); line_decimal(&line, m->bytes[2]);
    }
    if (event->synthetic) line_text(&line, " RELEASE");
    line_commit(&line);
}
static void route_event(void *context, const sourced_midi_event *event)
{
    unsigned index = event->source_port - 1;
    (void)context;
    if (event->synthetic) ++midi_synthetic_releases[index];
    else ++midi_events_received[index];
    if(!bt_score_active())midi_on_event(event);
}
static void log_ready(unsigned port, const usb_host *host)
{
    log_line line = {{0}, 0};
    line_source(&line, port); line_text(&line, " MIDI ready VID=");
    line_hex(&line, host->vid, 4); line_text(&line, " PID=");
    line_hex(&line, host->pid, 4); line_text(&line, " interface=");
    line_hex(&line, host->midi.interface_number, 2); line_text(&line, " IN=");
    line_hex(&line, host->midi.endpoint_in, 2); line_text(&line, " MPS=");
    line_hex(&line, host->midi.max_packet_size, 4); line_commit(&line);
}
static void log_session_end(unsigned port, int detached)
{
    log_line line = {{0}, 0};
    line_source(&line, port);
    line_text(&line, detached ? " disconnected; releasing source notes" :
                               " session reset; releasing source notes");
    line_commit(&line);
}
static void log_port_status(unsigned port, usb_host *host)
{
    static const char *const names[] = {
        "DETACHED", "DEBOUNCE", "RESET", "RECOVERY", "ENUM", "READY", "RETRY"
    };
    log_line line = {{0}, 0};
    unsigned line_state = usb_host_line(host);
    line_source(&line, port); line_text(&line, " state=");
    line_text(&line, (unsigned)host->state < sizeof(names) / sizeof(names[0]) ?
                    names[host->state] : "INVALID");
    line_text(&line, " D+="); line_decimal(&line, line_state & 1u);
    line_text(&line, " D-="); line_decimal(&line, (line_state >> 1) & 1u);
    line_text(&line, " errors="); line_decimal(&line, host->errors);
    if (host->last_error) {
        line_text(&line, " err=");
        if (host->last_error < 0) line_char(&line, '-');
        line_decimal(&line, (unsigned)(host->last_error < 0 ? -host->last_error : host->last_error));
    }
    line_commit(&line);
}

static void log_tinyf_status(void)
{
    log_line line = {{0}, 0};
    const tinyf_status *t = &tinyf_diagnostics;
    line_text(&line, "TinyF EN="); line_decimal(&line, t->enabled);
    line_text(&line, " PLAY="); line_decimal(&line, t->playing);
    line_text(&line, " Pmm="); line_decimal(&line, t->sensor[0].distance_mm);
    line_text(&line, " Vmm="); line_decimal(&line, t->sensor[1].distance_mm);
    line_text(&line, " P_mHz="); line_decimal(&line, t->sensor[0].measured_millihz);
    line_text(&line, " V_mHz="); line_decimal(&line, t->sensor[1].measured_millihz);
    line_text(&line, " bad="); line_decimal(&line, t->sensor[0].rejected);
    line_char(&line, '/'); line_decimal(&line, t->sensor[1].rejected);
    line_commit(&line);
}

static void log_console_status(void)
{
    log_line line = {{0}, 0};
    line_text(&line,"UI page=");line_decimal(&line,console_ui.page);
    line_text(&line," frames=");line_decimal(&line,console_ui.frames);
    line_text(&line," hb=");line_decimal(&line,console_ui.heartbeat);
    line_text(&line," stop=");line_decimal(&line,console_ui.stopped);
    line_text(&line," test=");line_decimal(&line,console_ui.test_count);
    line_text(&line," fs_ref=");line_decimal(&line,console_ui.fs_reference);
    line_commit(&line);
    line.length=0;
    line_text(&line,"AUDIO enq=");line_decimal(&line,audio_events_enqueued);
    line_text(&line," sent=");line_decimal(&line,audio_events_sent);
    line_text(&line," swq=");line_decimal(&line,audio_queue_overflows);
    line_text(&line," hwfifo=");line_decimal(&line,audio_fifo_rejections);
    line_text(&line," flags=");line_hex(&line,console_ui.audio[8],3);
    line_text(&line," fft=");line_hex(&line,console_ui.audio[24],1);
    line_text(&line," ui_cyc=");line_decimal(&line,console_poll_max_cycles);
    line_text(&line," loop_cyc=");line_decimal(&line,main_loop_max_cycles);
    line_commit(&line);
    // Bounded UART telemetry lets soak tests run without periodic debug halts.
    if (loop_ui.present) {
        line.length=0;
        line_text(&line,"LOOP st=");line_hex(&line,loop_ui.status[0],8);
        line_text(&line," p=");line_decimal(&line,loop_ui.status[3]);
        line_text(&line," n=");line_decimal(&line,loop_ui.status[2]);
        line_text(&line," f=");line_hex(&line,loop_ui.status[4],8);
        line_text(&line," g=");line_decimal(&line,loop_ui.status[15]);
        line_text(&line," u=");line_decimal(&line,loop_ui.status[11]);
        line_text(&line," max=");line_decimal(&line,loop_ui.status[12]);line_commit(&line);
        line.length=0;
        line_text(&line,"LOOPCLK hi=");line_decimal(&line,loop_ui.status[6]);
        line_text(&line," lo=");line_decimal(&line,loop_ui.status[5]);
        line_text(&line," done=");line_decimal(&line,loop_ui.status[13]);
        line_text(&line," od=");line_decimal(&line,loop_ui.status[14]);
        line_text(&line," clips=");line_decimal(&line,loop_ui.status[10]);
        line_text(&line," drop=");line_decimal(&line,midi_log_dropped_lines);line_commit(&line);
    }
}

int main(void)
{
    unsigned i, first = 0;
    uint8_t enabled[2] = {0, 0};
    uint32_t announced_generation[2] = {0, 0};
    uint32_t next_status = 0;
    uart_init(115200);
    if (tinyf_theremin_init(millis(0)) != 0)
        log_message("TinyF hardware ID mismatch: laser controls disabled");
    if(audio_midi_init()!=0)log_message("Audio hardware ID mismatch: load midi_audio FPGA image");
    log_message("AE350 dual USB MIDI host: USB1 KEYBOARD, USB2 DRUM");
    for (i = 0; i < 2; ++i) {
        const usb_host_io io = {&usb_contexts[i], reg_read, reg_write, millis};
        if (usb_host_init(&hosts[i], &io) == 0) enabled[i] = 1;
        else {
            log_line line = {{0}, 0};
            line_source(&line, i + 1);
            line_text(&line, " hardware ID mismatch; load dual USB FPGA bitstream");
            line_commit(&line);
        }
    }
    console_ui_init(millis(0));
    bt_score_init();
    if(bt_status.state==BT_FAULT && bt_status.reason==BT_NOT_READY)log_message("BT24 DLM memory check failed; score playback disabled");
    midi_router_init(&router, route_event, 0);
    for (;;) {
        uint32_t loop_started=cycle_low(),ui_started,cycles;
        ++midi_main_iterations;
        /* Alternate service order, and give each active host one bounded step.
         * An unresponsive/resetting device cannot hold up the other source.
         */
        for (unsigned turn = 0; turn < 2; ++turn) {
            unsigned index = (first + turn) & 1u;
            unsigned port = index + 1;
            usb_host *host = &hosts[index];
            int length, was_ready;
            if (!enabled[index]) continue;
            if (host->state == USB_HOST_READY && midi_router_is_releasing(&router, port)) {
                /* Backpressure only this reattached source until old notes are
                 * released. SOF continues in hardware; the other host runs.
                 * A device's finite internal FIFO may overflow if held too long.
                 */
                ++midi_backpressure_loops[index];
                continue;
            }
            was_ready = host->state == USB_HOST_READY;
            length = usb_host_step(host);
            usb_errors[index] = host->errors;
            if (was_ready && host->state != USB_HOST_READY) {
                if(!bt_score_active())audio_midi_disconnect(port);
                midi_router_disconnect(&router, port);
                log_session_end(port, host->state == USB_HOST_DETACHED);
            }
            if (host->state == USB_HOST_READY &&
                announced_generation[index] != host->generation) {
                announced_generation[index] = host->generation;
                log_ready(port, host);
            }
            if (length > 0) {
                for (int offset = 0; offset < length; offset += 4) {
                    midi_event event;
                    if (length - offset < 4 ||
                        !usb_midi1_decode(host->packet + offset, &event)) {
                        ++midi_decode_rejected[index];
                        continue;
                    }
                    if(!bt_score_active() && event.kind==MIDI_NOTE_ON)console_ui_midi(port,event.bytes[1],event.bytes[2]);
                    midi_router_deliver(&router, port, &event);
                }
            }
        }
        first ^= 1u;
        midi_router_step(&router);
        bt_score_poll(microseconds());
        audio_midi_poll();
        tinyf_theremin_poll(millis(0));
        ui_started=cycle_low();
        console_ui_poll(millis(0),(hosts[0].state==USB_HOST_READY?1u:0u)|(hosts[1].state==USB_HOST_READY?2u:0u),midi_decode_rejected[0]+midi_decode_rejected[1]);
        cycles=cycle_low()-ui_started;if(cycles>console_poll_max_cycles)console_poll_max_cycles=cycles;
        {
            uint32_t now = millis(0);
            if ((int32_t)(now - next_status) >= 0) {
                next_status = now + 2000u;
                for (i = 0; i < 2; ++i)
                    if (enabled[i]) log_port_status(i + 1, &hosts[i]);
                if (tinyf_diagnostics.present) log_tinyf_status();
                log_console_status();
            }
        }
        log_drain();
        cycles=cycle_low()-loop_started;if(cycles>main_loop_max_cycles)main_loop_max_cycles=cycles;
    }
}
