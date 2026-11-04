#include "tinyf_theremin.h"
#include <string.h>
#ifndef TINYF_HOST_TEST
#include "platform.h"
#endif

#define UART_DATA 0x20u
#define UART_IER 0x24u
#define UART_FCR 0x28u
#define UART_LCR 0x2cu
#define UART_LSR 0x34u
#define RX_READY 1u
#define RX_ERRORS 0x1eu
#define TX_READY 0x20u
#define TX_EMPTY 0x40u
#define RX_BUDGET 24u
#define STALE_MS 120u
tinyf_status tinyf_diagnostics;
volatile uint8_t tinyf_raw[2][TINYF_RAW_SIZE];
volatile uint32_t tinyf_raw_head[2];
static uint32_t pending_rx_errors[2];

#ifdef TINYF_HOST_TEST
extern uint32_t tinyf_test_reg_read(unsigned offset);
extern void tinyf_test_reg_write(unsigned offset, uint32_t value);
extern uint32_t tinyf_test_uart_read(unsigned index, unsigned offset);
extern void tinyf_test_uart_write(unsigned index, unsigned offset, uint32_t value);
#define read_reg tinyf_test_reg_read
#define write_reg tinyf_test_reg_write
#define uart_read tinyf_test_uart_read
#define uart_write tinyf_test_uart_write
#else
static uint32_t read_reg(unsigned offset)
{
    __asm__ volatile("fence iorw, iorw" ::: "memory");
    return *(volatile uint32_t *)(uintptr_t)(TINYF_BASE + offset);
}
static void write_reg(unsigned offset, uint32_t value)
{
    *(volatile uint32_t *)(uintptr_t)(TINYF_BASE + offset) = value;
    __asm__ volatile("fence iorw, iorw" ::: "memory");
}
static uint32_t uart_read(unsigned index, unsigned offset)
{
    return *(volatile uint32_t *)(uintptr_t)(0xf0200000u + index * 0x100000u + offset);
}
static void uart_write(unsigned index, unsigned offset, uint32_t value)
{
    *(volatile uint32_t *)(uintptr_t)(0xf0200000u + index * 0x100000u + offset) = value;
}
#endif

/* LSR line-error bits are read-to-clear. TX-empty/ready queries must retain
 * those bits until the RX consumer discards the damaged line. UARTs are owned
 * by this single main loop; no ISR accesses LSR or the receive FIFO. */
static uint32_t read_uart_status(unsigned index)
{
    uint32_t status = uart_read(index, UART_LSR);
    pending_rx_errors[index] |= status & RX_ERRORS;
    return status | pending_rx_errors[index];
}

/* 65 steps over C3..C5, equal pitch spacing. PLL=50 MHz*29/(2*14.75),
 * I2S Fs=PLL/1024=11328125/236 Hz. Linear interpolation <0.11 cent error;
 * no floating point or exp library in the embedded image. */
static const uint32_t pitch_steps[65] = {
    11704800u,11961102u,12223016u,12490665u,12764175u,13043674u,13329294u,13621167u,
    13919432u,14224228u,14535698u,14853988u,15179248u,15511631u,15851291u,16198389u,
    16553088u,16915553u,17285955u,17664469u,18051270u,18446541u,18850468u,19263240u,
    19685050u,20116096u,20556581u,21006712u,21466699u,21936758u,22417111u,22907982u,
    23409601u,23922205u,24446033u,24981331u,25528351u,26087349u,26658588u,27242335u,
    27838864u,28448456u,29071396u,29707977u,30358497u,31023261u,31702582u,32396778u,
    33106175u,33831106u,34571911u,35328937u,36102540u,36893083u,37700936u,38526479u,
    39370099u,40232192u,41113162u,42013423u,42933398u,43873517u,44834221u,45815963u,
    46819202u
};
static uint16_t near_distance[2]={100,100},far_distance[2]={600,600};
static unsigned mapping_low=48,mapping_high=72,smoothing_time=25;
static uint32_t console_controls;
static uint8_t console_controls_enabled;
static const uint32_t calibrated_steps[193]={
5852400u,5937525u,6023889u,6111508u,6200402u,6290589u,6382088u,6474917u,
6569097u,6664647u,6761586u,6859936u,6959716u,7060947u,7163651u,7267849u,
7373562u,7480813u,7589624u,7700018u,7812017u,7925645u,8040927u,8157885u,
8276544u,8396929u,8519065u,8642978u,8768693u,8896236u,9025635u,9156916u,
9290106u,9425234u,9562327u,9701414u,9842525u,9985688u,10130933u,10278291u,
10427792u,10579467u,10733349u,10889470u,11047861u,11208555u,11371588u,11536991u,
11704800u,11875051u,12047777u,12223016u,12400804u,12581178u,12764175u,12949835u,
13138194u,13329294u,13523173u,13719872u,13919432u,14121895u,14327303u,14535698u,
14747125u,14961626u,15179248u,15400036u,15624034u,15851291u,16081853u,16315769u,
16553088u,16793858u,17038130u,17285955u,17537385u,17792473u,18051270u,18313832u,
18580213u,18850468u,19124654u,19402829u,19685050u,19971375u,20261866u,20556581u,
20855584u,21158935u,21466699u,21778939u,22095721u,22417111u,22743175u,23073982u,
23409601u,23750101u,24095555u,24446033u,24801608u,25162356u,25528351u,25899669u,
26276389u,26658588u,27046346u,27439744u,27838864u,28243790u,28654605u,29071396u,
29494249u,29923253u,30358497u,30800071u,31248068u,31702582u,32163707u,32631539u,
33106175u,33587716u,34076260u,34571911u,35074771u,35584945u,36102540u,36627664u,
37160425u,37700936u,38249309u,38805658u,39370099u,39942750u,40523731u,41113162u,
41711167u,42317870u,42933398u,43557878u,44191442u,44834221u,45486350u,46147964u,
46819202u,47500203u,48191109u,48892065u,49603217u,50324712u,51056702u,51799339u,
52552777u,53317175u,54092691u,54879488u,55677728u,56487579u,57309210u,58142792u,
58988498u,59846506u,60716993u,61600142u,62496137u,63405164u,64327413u,65263077u,
66212350u,67175431u,68152520u,69143822u,70149542u,71169890u,72205080u,73255327u,
74320850u,75401872u,76498618u,77611316u,78740198u,79885501u,81047462u,82226325u,
83422334u,84635740u,85866795u,87115756u,88382884u,89668443u,90972700u,92295929u,
93638404u
};
static uint32_t calibrated_pitch(unsigned distance)
{
 unsigned span=far_distance[0]-near_distance[0],position,index,rem;
 if(distance<near_distance[0])distance=near_distance[0];
 if(distance>far_distance[0])distance=far_distance[0];
 position=((mapping_low-36u)*4u*span)+(far_distance[0]-distance)*(mapping_high-mapping_low)*4u;
 index=position/span;rem=position%span;
 if(index>=192)return calibrated_steps[192];
 return calibrated_steps[index]+(uint32_t)(((uint64_t)(calibrated_steps[index+1]-calibrated_steps[index])*rem+span/2)/span);
}

uint32_t tinyf_theremin_pitch_step(unsigned distance)
{
    unsigned position, index, fraction;
    if(near_distance[0]!=100 || far_distance[0]!=600 || mapping_low!=48 || mapping_high!=72)return calibrated_pitch(distance);
    if (distance <= 100u) return pitch_steps[64];
    if (distance >= 600u) return pitch_steps[0];
    position = (600u - distance) * 64u;
    index = position / 500u; fraction = position % 500u;
    return pitch_steps[index] + (uint32_t)(((uint64_t)
        (pitch_steps[index+1u] - pitch_steps[index]) * fraction + 250u) / 500u);
}
uint32_t tinyf_theremin_volume(unsigned distance)
{
    unsigned span=far_distance[1]-near_distance[1];
    if (distance <= near_distance[1]) return 0;
    if (distance >= far_distance[1]) return 65536u;
    return ((distance-near_distance[1])*65536u+span/2u)/span;
}
static void stop_playing(void)
{
    tinyf_diagnostics.playing = 0;
    tinyf_diagnostics.sensor[0].recovery_frames = 0;
    tinyf_diagnostics.sensor[1].recovery_frames = 0;
}
static int fresh(const tinyf_sensor *s, uint32_t now)
{
    return s->have_valid && (uint32_t)(now - s->last_valid_ms) < STALE_MS;
}
static void measure_rate(tinyf_sensor *s, uint32_t now)
{
    uint32_t elapsed;
    s->last_frame_ms = now;
    if (!s->rate_frames) {s->rate_start_ms = now; s->rate_frames = 1; return;}
    ++s->rate_frames;
    elapsed = now - s->rate_start_ms;
    if (elapsed < 1000u) return;
    s->measured_millihz = (uint32_t)(((uint64_t)(s->rate_frames-1u) * 1000000u) / elapsed);
    s->rate_result = s->measured_millihz >= 75000u && s->measured_millihz <= 105000u ? 3u :
        s->measured_millihz >= 45000u && s->measured_millihz < 75000u ? 2u :
        s->measured_millihz >= 20000u && s->measured_millihz < 45000u ? 1u : 0u;
    s->rate_start_ms = now; s->rate_frames = 1;
}
static int parse_line(const char *line, unsigned length, unsigned *distance, unsigned *confidence)
{
    unsigned i = 1, digits = 0, value = 0;
    if (length < 5u || line[0] != ' ') return 0;
    while (i < length && line[i] >= '0' && line[i] <= '9') {
        if (++digits > 5u) return 0;
        value = value * 10u + (unsigned)(line[i++] - '0');
    }
    if (!digits || i+2u >= length || line[i++] != ',' || line[i++] != ' ') return 0;
    *distance = value; value = 0; digits = 0;
    while (i < length && line[i] >= '0' && line[i] <= '9') {
        if (++digits > 3u) return 0;
        value = value * 10u + (unsigned)(line[i++] - '0');
    }
    if (!digits || i != length || value > TINYF_MAX_CONFIDENCE) return 0;
    *confidence = value; return 1;
}
static void reject(tinyf_sensor *s)
{
    ++s->rejected; s->recovery_frames = 0;
}
static void feed(unsigned index, unsigned byte, uint32_t now)
{
    tinyf_sensor *s = &tinyf_diagnostics.sensor[index];
    unsigned distance, confidence;
    uint32_t position = tinyf_raw_head[index];
    tinyf_raw[index][position & (TINYF_RAW_SIZE-1u)] = (uint8_t)byte;
    tinyf_raw_head[index] = position + 1u;
    ++s->bytes;
    if (s->discard) {if (byte == '\n') {s->discard = 0; s->length = 0;} return;}
    if (byte != '\n') {
        if (s->length >= 11u) {reject(s); s->discard = 1; s->length = 0;}
        else s->line[s->length++] = (char)byte;
        return;
    }
    if (!parse_line(s->line, s->length, &distance, &confidence)) {
        reject(s); s->length = 0; return;
    }
    s->length = 0; ++s->frames; measure_rate(s, now);
    if (distance < 20u || distance > 4500u || confidence < TINYF_MIN_CONFIDENCE) {
        reject(s); return;
    }
    ++s->valid_frames; s->have_valid = 1;
    s->last_valid_ms = now; s->distance_mm = (uint16_t)distance;
    s->confidence = (uint8_t)confidence;
    if (distance > far_distance[index]+50u) {stop_playing(); return;}
    if (distance <= far_distance[index]) s->target_mm = (uint16_t)distance;
    if (distance >= near_distance[index] && distance <= far_distance[index] && tinyf_diagnostics.enabled) {
        if (s->recovery_frames < 2u) ++s->recovery_frames;
    } else s->recovery_frames = 0;
}
static void receive(unsigned index, uint32_t now)
{
    tinyf_sensor *s = &tinyf_diagnostics.sensor[index];
    unsigned budget = RX_BUDGET;
    while (budget--) {
        uint32_t status = read_uart_status(index);
        if (status & RX_ERRORS) {
            pending_rx_errors[index] = 0;
            ++s->uart_errors; reject(s); s->length = 0; s->discard = 1;
            if (status & RX_READY) (void)uart_read(index, UART_DATA);
            continue;
        }
        if (!(status & RX_READY)) break;
        feed(index, uart_read(index, UART_DATA) & 255u, now);
    }
}
static void configure(uint32_t now, uint16_t request)
{
    static const uint8_t command[] = {0x55,0xaa,0x96,0x02,0x00,0x5a,0xfa};
    tinyf_status *t = &tinyf_diagnostics;
    unsigned index;
    if (!t->config_phase && request != t->seen_request) {
        t->seen_request = request; ++t->config_requests;
        t->config_phase = 1; t->config_start_ms = now; t->tx_stalled = 0;
        t->tx_index[0] = t->tx_index[1] = 0;
    }
    if (!t->config_phase) return;
    /* Pause log producer before draining UART2, then switch only at TEMT.
     * Each visit writes at most one byte per UART and never busy-waits. */
    if (now - t->config_start_ms >= 250u) t->tx_stalled = 1;
    if (t->config_phase == 1) {
        if (!(read_uart_status(0) & TX_EMPTY) || !(read_uart_status(1) & TX_EMPTY)) return;
        write_reg(TINYF_ROUTE_REG,1u); t->config_phase = 2;
    }
    if (t->config_phase == 2) {
        for (index = 0; index < 2; ++index)
            if (t->tx_index[index] < sizeof(command) && (read_uart_status(index) & TX_READY))
                uart_write(index,UART_DATA,command[t->tx_index[index]++]);
        if (t->tx_index[0] != sizeof(command) || t->tx_index[1] != sizeof(command)) return;
        t->config_phase = 3;
    }
    if (t->config_phase == 3 && (read_uart_status(0) & TX_EMPTY) && (read_uart_status(1) & TX_EMPTY)) {
        write_reg(TINYF_ROUTE_REG,0u); t->config_phase = 0;
        for (index = 0; index < 2; ++index) {
            t->sensor[index].rate_frames = 0;
            t->sensor[index].rate_result = 0;
            t->sensor[index].measured_millihz = 0;
        }
    }
}
static uint32_t smooth(uint32_t value, uint32_t target, uint32_t dt)
{
    int64_t delta = ((int64_t)target - value) * dt / (smoothing_time + dt);
    if (!delta && value != target) return value < target ? value+1u : value-1u;
    return (uint32_t)((int64_t)value + delta);
}
int tinyf_theremin_init(uint32_t now)
{
    unsigned i;
    uint32_t divisor;
    tinyf_status *t = &tinyf_diagnostics;
    memset(t,0,sizeof(*t));
    console_controls_enabled=0;console_controls=0;
    memset(pending_rx_errors,0,sizeof(pending_rx_errors));
    for (i = 0; i < 2; ++i) {
        unsigned j;
        tinyf_raw_head[i] = 0;
        for (j = 0; j < TINYF_RAW_SIZE; ++j) tinyf_raw[i][j] = 0;
    }
    t->step = tinyf_theremin_pitch_step(600);
    t->sensor[0].target_mm = 600; t->sensor[1].target_mm = 100;
    t->last_update_ms = now; t->dirty = 1;
    t->present = read_reg(TINYF_ID_REG) == TINYF_ID;
    if (!t->present) return -1;
    t->seen_request = (uint16_t)(read_reg(TINYF_UI_REG) >> 16);
    write_reg(TINYF_ROUTE_REG,0);
    divisor = (50000000u + 8u*115200u)/(16u*115200u);
    for (i = 0; i < 2; ++i) {
        uart_write(i,UART_LCR,0x80u);
        uart_write(i,UART_DATA,divisor & 255u);
        uart_write(i,UART_IER,divisor >> 8);
        uart_write(i,UART_LCR,3u);
        uart_write(i,UART_IER,0);
        uart_write(i,UART_FCR,7u);
    }
    return 0;
}
int tinyf_theremin_log_paused(void)
{
    return tinyf_diagnostics.present && tinyf_diagnostics.config_phase != 0;
}
int tinyf_theremin_log_ready(void)
{
    return !tinyf_theremin_log_paused() && (read_uart_status(1) & TX_READY) != 0;
}
void tinyf_theremin_poll(uint32_t now)
{
    tinyf_status *t = &tinyf_diagnostics;
    uint32_t ui, dt, step, gain, feedback;
    unsigned i;
    if (!t->present) return;
    ui = console_controls_enabled ? console_controls : read_reg(TINYF_UI_REG);
    if ((ui & 1u) != t->enabled) {
        t->enabled = (uint8_t)(ui & 1u); stop_playing();
    }
    t->mix_percent = (uint8_t)((ui >> 8)&255u);
    if (t->mix_percent > 100u) t->mix_percent = 100u;
    configure(now,(uint16_t)(ui >> 16));
    /* Expiry is checked before consuming queued frames: old recovery evidence
     * cannot keep a voice armed across a communications gap. */
    if (!fresh(&t->sensor[0],now) || !fresh(&t->sensor[1],now)) stop_playing();
    receive(0,now); receive(1,now);
    if (t->enabled && t->sensor[0].recovery_frames >= 2u && t->sensor[1].recovery_frames >= 2u &&
        fresh(&t->sensor[0],now) && fresh(&t->sensor[1],now)) t->playing = 1;
    dt = now - t->last_update_ms;
    if (dt) {
        t->last_update_ms = now; if (dt > 25u) dt = 25u;
        step = tinyf_theremin_pitch_step(t->sensor[0].target_mm);
        t->step = smooth(t->step,step,dt);
        gain = t->playing ? tinyf_theremin_volume(t->sensor[1].target_mm) : 0u;
        t->gain = t->playing ? smooth(t->gain,gain,dt) : 0u;
        t->mix = t->enabled ? ((uint32_t)t->mix_percent*65536u+50u)/100u : 0u;
        t->dirty = 1;
    }
    /* Stop/disable bypasses the software low-pass; RTL ramps this target down
     * over about 10 ms without truncating the shared reverb tail. */
    if (!t->playing && t->gain) {t->gain = 0; t->dirty = 1;}
    if (!t->enabled && t->mix) {t->mix = 0; t->dirty = 1;}
    if (t->dirty) {
        if (read_reg(TINYF_BUSY_REG)&1u) ++t->busy_polls;
        else {
            write_reg(TINYF_STEP_REG,t->step); write_reg(TINYF_GAIN_REG,t->gain);
            write_reg(TINYF_MIX_REG,t->mix); write_reg(TINYF_COMMIT_REG,1u);
            ++t->commits; t->dirty = 0;
        }
    }
    feedback = 1u | ((uint32_t)t->enabled<<1) | ((uint32_t)t->playing<<2) |
        ((uint32_t)(t->config_phase!=0)<<3) | ((uint32_t)t->tx_stalled<<6);
    for (i = 0; i < 2; ++i) {
        tinyf_sensor *s = &t->sensor[i];
        if (fresh(s,now)) feedback |= 1u << (4u+i);
        if (s->rate_frames && now-s->last_frame_ms >= 1000u) {
            s->rate_result = 0; s->measured_millihz = 0; s->rate_frames = 0;
        }
        feedback |= (uint32_t)s->rate_result << (8u+2u*i);
    }
    write_reg(TINYF_FEEDBACK_REG,feedback);
}

int tinyf_theremin_set_mapping(const uint16_t near_mm[2],const uint16_t far_mm[2],unsigned low_note,unsigned high_note,unsigned smoothing_ms)
{
 if(low_note<36 || high_note>84 || low_note>=high_note || smoothing_ms<1 || smoothing_ms>100)return -1;
 for(unsigned i=0;i<2;++i)if(near_mm[i]<20 || far_mm[i]>4000 || near_mm[i]+10u>far_mm[i])return -1;
 stop_playing();tinyf_diagnostics.gain=0;tinyf_diagnostics.dirty=1;
 for(unsigned i=0;i<2;++i){near_distance[i]=near_mm[i];far_distance[i]=far_mm[i];tinyf_diagnostics.sensor[i].target_mm=far_mm[i];}
 mapping_low=low_note;mapping_high=high_note;smoothing_time=smoothing_ms;return 0;
}
unsigned tinyf_theremin_pitch_position(uint32_t step)
{
 // Returns near-high position 0..1023, continuous and using the active map.
 uint32_t low=tinyf_theremin_pitch_step(far_distance[0]),high=tinyf_theremin_pitch_step(near_distance[0]);
 if(step>=high)return 0;
 if(step<=low)return 1023;
 unsigned lo=near_distance[0],hi=far_distance[0];
 while(hi-lo>1){unsigned mid=(lo+hi)/2;if(tinyf_theremin_pitch_step(mid)>step)lo=mid;else hi=mid;}
 return ((hi-near_distance[0])*1023u)/(far_distance[0]-near_distance[0]);
}
unsigned tinyf_theremin_mapping(unsigned field)
{
 switch(field){case 0:return near_distance[0];case 1:return far_distance[0];
 case 2:return near_distance[1];case 3:return far_distance[1];case 4:return mapping_low;
 case 5:return mapping_high;default:return smoothing_time;}
}

void tinyf_theremin_console_control(unsigned enabled,unsigned mix,unsigned request)
{
 console_controls=(enabled?1u:0u)|((mix>100?100u:mix)<<8)|((uint32_t)(uint16_t)request<<16);
 console_controls_enabled=1;
}
