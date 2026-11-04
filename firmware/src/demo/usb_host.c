#include "usb_host.h"
#include <string.h>

enum { CTRL=0, STATUS=4, IRQ_ACK=8, IRQ_MASK=16, XFER_LEN=20,
       TOKEN=24, RX_STAT=28, FIFO=32, IDENT=240, PORT_COUNT=248 };
enum { PID_OUT=0xe1, PID_IN=0x69, PID_SETUP=0x2d,
       DATA0=0xc3, DATA1=0x4b, ACK=0xd2, NAK=0x5a, STALL=0x1e };
enum { E_DEVICE8, E_ADDRESS, E_ADDRESS_WAIT, E_DEVICE18, E_CONFIG9,
       E_CONFIG_ALL, E_CONFIGURATION, E_CONFIG_WAIT };
enum { C_SETUP, C_DATA, C_STATUS };
#define START (1u<<31)
#define IDLE (1u<<28)
#define RX_ERRORS ((1u<<30)|(1u<<29))
#define NORMAL_CTRL 0xe9u
#define PENDING (-100)

static uint32_t rd(usb_host *h,unsigned r) { return h->io.read(h->io.context,r); }
static void wr(usb_host *h,unsigned r,uint32_t v) { h->io.write(h->io.context,r,v); }
static int due(uint32_t now,uint32_t deadline) { return (int32_t)(now-deadline)>=0; }
static uint16_t le16(const uint8_t *p) { return p[0]|((uint16_t)p[1]<<8); }
static void quiet(usb_host *h)
{
    h->control=NORMAL_CTRL & ~1u;
    wr(h,CTRL,h->control|256u);
}
static void fail(usb_host *h,int error,uint32_t now,int count)
{
    if (count) ++h->errors;
    h->last_error=error;
    if (h->transfer_active) h->discard_rx=1;
    h->transfer_active=0; h->control_active=0; h->idle_waiting=0;
    h->se0_seen=0;
    quiet(h);
    h->state=USB_HOST_RETRY_DELAY; h->deadline=now+500u;
}
unsigned usb_host_line(usb_host *h) { return rd(h,STATUS)&3u; }
int usb_host_init(usb_host *h,const usb_host_io *io)
{
    if (!h || !io || !io->read || !io->write || !io->now_ms) return USB_HARDWARE;
    memset(h,0,sizeof(*h)); h->io=*io; h->ep0_size=8;
    if (rd(h,IDENT)!=0x554d0201u || rd(h,PORT_COUNT)!=2u) {
        h->last_error=USB_HARDWARE; return USB_HARDWARE;
    }
    wr(h,IRQ_MASK,0); quiet(h); wr(h,IRQ_ACK,15);
    h->state=USB_HOST_DETACHED;
    return 0;
}

/* Returns 1 if started, PENDING while an old SIE operation is still active,
 * or an error after a bounded idle wait. Never overwrite a pending token.
 */
static int start_transfer(usb_host *h,uint32_t now,int input,uint8_t pid,
                          uint8_t endpoint,unsigned toggle,
                          const uint8_t *tx,unsigned length)
{
    uint32_t s=rd(h,RX_STAT),token; unsigned i;
    if ((s&START) || !(s&IDLE)) {
        if (!h->idle_waiting) { h->idle_waiting=1; h->idle_wait_at=now; }
        if ((uint32_t)(now-h->idle_wait_at)>=20u) {
            ++h->sw_timeouts; h->error_rx_status=s; h->error_bus_status=0;
            return USB_TIMEOUT;
        }
        return PENDING;
    }
    h->idle_waiting=0;
    if (h->discard_rx) {
        /* An IN can finish after a software timeout/disconnect. Drain it once
         * before re-enumeration; the TX flush bit does not flush the RX FIFO.
         */
        unsigned stale=s&0xffffu;
        if (stale>sizeof(h->packet)) stale=sizeof(h->packet);
        for (i=0;i<stale;++i) (void)rd(h,FIFO);
        h->discard_rx=0;
        return PENDING;
    }
    wr(h,CTRL,h->control|256u); wr(h,IRQ_ACK,6);
    for (i=0;i<length;++i) wr(h,FIFO,tx[i]);
    wr(h,XFER_LEN,length);
    token=START|(1u<<29)|((uint32_t)pid<<16)|((uint32_t)h->address<<9)|
          ((endpoint&15u)<<5);
    if (input) token|=1u<<30;
    if (toggle) token|=1u<<28;
    wr(h,TOKEN,token);
    h->transfer_at=now; h->transfer_active=1;
    h->transfer_input=(uint8_t)input; h->transfer_toggle=(uint8_t)toggle;
    return 1;
}
/* One completion, with at most 64 FIFO reads. Error packets are drained so
 * stale bytes cannot leak into a subsequent transaction. No retry loop.
 */
static int finish_transfer(usb_host *h,uint32_t now,unsigned capacity)
{
    uint32_t s=rd(h,RX_STAT),bus_status=0; unsigned count,i; uint8_t response;
    if ((s&START) || !(s&IDLE)) {
        if ((uint32_t)(now-h->transfer_at)<20u) return PENDING;
        ++h->sw_timeouts; h->error_rx_status=s; h->error_bus_status=0;
        h->transfer_active=0; h->discard_rx=1; return USB_TIMEOUT;
    }
    h->transfer_active=0; response=(uint8_t)(s>>16);
    count=h->transfer_input ? s&0xffffu : 0u;
    if (count>sizeof(h->packet)) return USB_OVERFLOW;
    for (i=0;i<count;++i) h->packet[i]=(uint8_t)rd(h,FIFO);
    if (!(s&RX_ERRORS)) bus_status=rd(h,STATUS);
    if ((s&RX_ERRORS) || (bus_status&4u)) {
        h->hw_timeouts+=(s>>29)&1u; h->crc_errors+=(s>>30)&1u;
        h->phy_errors+=(bus_status>>2)&1u;
        h->error_rx_status=s; h->error_bus_status=bus_status;
        return USB_TIMEOUT;
    }
    if (response==NAK) { ++h->nak_count; return USB_NAK; }
    if (response==STALL) return USB_STALL;
    if (!h->transfer_input) return response==ACK ? 0 : USB_PROTOCOL;
    if (response!=DATA0 && response!=DATA1) return USB_PROTOCOL;
    if (count>capacity) return USB_OVERFLOW;
    if (response!=(h->transfer_toggle ? DATA1 : DATA0)) return USB_DUPLICATE;
    return (int)count;
}
static void control_begin(usb_host *h,uint32_t now,uint8_t type,uint8_t request,
                          uint16_t value,uint8_t *buffer,uint16_t length)
{
    h->setup[0]=type; h->setup[1]=request;
    h->setup[2]=(uint8_t)value; h->setup[3]=(uint8_t)(value>>8);
    h->setup[4]=0; h->setup[5]=0;
    h->setup[6]=(uint8_t)length; h->setup[7]=(uint8_t)(length>>8);
    h->control_read=(type&128u)!=0; h->control_buffer=buffer;
    h->control_length=length; h->control_done=0; h->control_toggle=1;
    h->control_phase=C_SETUP; h->control_active=1;
    h->retry_at=now; h->retry_until=now+250u;
}
static int control_step(usb_host *h,uint32_t now)
{
    int r;
    if (!h->transfer_active) {
        if (!due(now,h->retry_at)) return PENDING;
        if (due(now,h->retry_until)) return USB_TIMEOUT;
        if (h->control_phase==C_SETUP)
            r=start_transfer(h,now,0,PID_SETUP,0,0,h->setup,8);
        else if (h->control_phase==C_DATA)
            r=start_transfer(h,now,1,PID_IN,0,h->control_toggle,0,0);
        else
            r=start_transfer(h,now,!h->control_read,
                             h->control_read?PID_OUT:PID_IN,0,1,0,0);
        return r==1 ? PENDING : r;
    }
    r=finish_transfer(h,now,h->ep0_size);
    if (r==PENDING) return PENDING;
    if (r==USB_NAK || r==USB_DUPLICATE) {
        if (due(now,h->retry_until)) return USB_TIMEOUT;
        h->retry_at=now+1u; return PENDING;
    }
    if (r<0) return r;
    if (h->control_phase==C_SETUP) {
        h->control_phase=h->control_length ? C_DATA : C_STATUS;
    } else if (h->control_phase==C_DATA) {
        if ((unsigned)r>(unsigned)(h->control_length-h->control_done)) return USB_OVERFLOW;
        if (r) memcpy(h->control_buffer+h->control_done,h->packet,(size_t)r);
        h->control_done+=(uint16_t)r; h->control_toggle^=1u;
        if ((unsigned)r<h->ep0_size || h->control_done==h->control_length)
            h->control_phase=C_STATUS;
    } else {
        if (r!=0) return USB_PROTOCOL;
        return h->control_read ? (int)h->control_done : 0;
    }
    h->retry_at=now; h->retry_until=now+250u;
    return PENDING;
}
static int valid_size(unsigned n) { return n==8 || n==16 || n==32 || n==64; }
static void enumeration_step(usb_host *h,uint32_t now)
{
    int r;
    if (!h->control_active) {
        switch (h->enum_stage) {
        case E_DEVICE8:
            control_begin(h,now,0x80,6,0x100,h->device,8); break;
        case E_ADDRESS:
            control_begin(h,now,0,5,1,0,0); break;
        case E_ADDRESS_WAIT:
            if (due(now,h->deadline)) { h->address=1; h->enum_stage=E_DEVICE18; }
            break;
        case E_DEVICE18:
            control_begin(h,now,0x80,6,0x100,h->device,18); break;
        case E_CONFIG9:
            control_begin(h,now,0x80,6,(uint16_t)(0x200+h->config_index),h->descriptor,9); break;
        case E_CONFIG_ALL:
            control_begin(h,now,0x80,6,(uint16_t)(0x200+h->config_index),
                          h->descriptor,h->config_length); break;
        case E_CONFIGURATION:
            control_begin(h,now,0,9,h->midi.configuration,0,0); break;
        case E_CONFIG_WAIT:
            if (due(now,h->deadline)) {
                h->input_toggle=0; h->consecutive_errors=0; h->last_error=0;
                h->next_poll=now; h->state=USB_HOST_READY; ++h->generation;
            }
            break;
        default: fail(h,USB_PROTOCOL,now,1); break;
        }
        return;
    }
    r=control_step(h,now);
    if (r==PENDING) return;
    h->control_active=0;
    if (r<0) { fail(h,r,now,1); return; }
    switch (h->enum_stage) {
    case E_DEVICE8:
        if (r!=8 || h->device[0]!=18 || h->device[1]!=1 || !valid_size(h->device[7])) {
            fail(h,USB_PROTOCOL,now,1); return;
        }
        h->ep0_size=h->device[7]; h->enum_stage=E_ADDRESS; break;
    case E_ADDRESS:
        h->enum_stage=E_ADDRESS_WAIT; h->deadline=now+3u; break;
    case E_DEVICE18:
        if (r!=18 || h->device[0]!=18 || h->device[1]!=1 ||
            h->device[7]!=h->ep0_size || !h->device[17]) {
            fail(h,USB_PROTOCOL,now,1); return;
        }
        h->vid=le16(h->device+8); h->pid=le16(h->device+10);
        h->config_index=0; h->enum_stage=E_CONFIG9; break;
    case E_CONFIG9:
        if (r!=9 || h->descriptor[0]<9 || h->descriptor[1]!=2) {
            fail(h,USB_PROTOCOL,now,1); return;
        }
        h->config_length=le16(h->descriptor+2);
        if (h->config_length<9 || h->config_length>sizeof(h->descriptor)) {
            fail(h,USB_OVERFLOW,now,1); return;
        }
        h->enum_stage=E_CONFIG_ALL; break;
    case E_CONFIG_ALL:
        if (r!=(int)h->config_length) { fail(h,USB_PROTOCOL,now,1); return; }
        r=usb_midi1_find_in(h->descriptor,h->config_length,&h->midi);
        if (r<0) { fail(h,USB_PROTOCOL,now,1); return; }
        if (!r) {
            if (++h->config_index<h->device[17]) h->enum_stage=E_CONFIG9;
            else fail(h,USB_PROTOCOL,now,1);
            return;
        }
        if (!valid_size(h->midi.max_packet_size)) { fail(h,USB_PROTOCOL,now,1); return; }
        h->enum_stage=E_CONFIGURATION; break;
    case E_CONFIGURATION:
        h->enum_stage=E_CONFIG_WAIT; h->deadline=now+10u; break;
    default: fail(h,USB_PROTOCOL,now,1); break;
    }
}
static int ready_step(usb_host *h,uint32_t now)
{
    int r;
    if (!h->transfer_active) {
        if (!due(now,h->next_poll)) return 0;
        r=start_transfer(h,now,1,PID_IN,h->midi.endpoint_in,h->input_toggle,0,0);
        if (r==1 || r==PENDING) return 0;
    } else {
        r=finish_transfer(h,now,h->midi.max_packet_size);
        if (r==PENDING) return 0;
    }
    h->next_poll=now+1u;
    if (r==USB_NAK || r==USB_DUPLICATE) { h->consecutive_errors=0; return 0; }
    if (r<0) {
        ++h->errors; h->last_error=r;
        /* A software20ms deadline can leave a late auto-ACKed IN in flight.
         * Re-enumerate this port rather than losing DATA-toggle alignment.
         */
        if (++h->consecutive_errors>=8 || r==USB_STALL || r==USB_OVERFLOW || h->discard_rx)
            fail(h,r,now,0);
        return 0;
    }
    h->input_toggle^=1u; h->consecutive_errors=0;
    if (r%4) { fail(h,USB_PROTOCOL,now,1); return 0; }
    return r;
}
int usb_host_step(usb_host *h)
{
    uint32_t now,bus_status; unsigned line,sof_phase;
    if (!h || h->last_error==USB_HARDWARE) return 0;
    now=h->io.now_ms(h->io.context);
    /* Only observe disconnect outside the deliberate SE0 reset interval.
     * STATUS[31:16] counts 48MHz clocks since the last autonomous SOF. Its
     * first20us include the host-driven J/EOP, which must neither start nor
     * clear a disconnect interval. Otherwise every SOF J pulse would keep a
     * truly disconnected device looking attached forever.
     */
    bus_status=rd(h,STATUS); line=bus_status&3u; sof_phase=bus_status>>16;
    if ((h->state==USB_HOST_READY || h->state==USB_HOST_ENUMERATING) &&
        (!(h->control&1u) || sof_phase>=960u)) {
        if (line==0) {
            if (!h->se0_seen) { h->se0_seen=1; h->se0_at=now; }
            else if ((uint32_t)(now-h->se0_at)>=10u) {
                fail(h,USB_PROTOCOL,now,0); return 0;
            }
        } else h->se0_seen=0;
    }
    switch (h->state) {
    case USB_HOST_DETACHED:
        if (line==1 || line==3) { h->state=USB_HOST_DEBOUNCE; h->deadline=now+100u; }
        break;
    case USB_HOST_DEBOUNCE:
        if (line==0 || line==2) h->state=USB_HOST_DETACHED;
        else if (due(now,h->deadline)) {
            h->address=0; h->ep0_size=8; h->input_toggle=0; h->control_active=0;
            h->transfer_active=0; h->idle_waiting=0; h->se0_seen=0;
            h->discard_rx=1;
            wr(h,CTRL,0xc4u); h->state=USB_HOST_RESET_ASSERT; h->deadline=now+20u;
        }
        break;
    case USB_HOST_RESET_ASSERT:
        if (due(now,h->deadline)) {
            h->control=NORMAL_CTRL; wr(h,CTRL,h->control|256u);
            h->state=USB_HOST_RESET_RECOVERY; h->deadline=now+20u;
        }
        break;
    case USB_HOST_RESET_RECOVERY:
        if (due(now,h->deadline)) {
            if (line==0 || line==2) fail(h,USB_PROTOCOL,now,1);
            else { h->state=USB_HOST_ENUMERATING; h->enum_stage=E_DEVICE8; }
        }
        break;
    case USB_HOST_ENUMERATING: enumeration_step(h,now); break;
    case USB_HOST_READY: return ready_step(h,now);
    case USB_HOST_RETRY_DELAY:
        if (due(now,h->deadline)) h->state=USB_HOST_DETACHED;
        break;
    default: fail(h,USB_PROTOCOL,now,1); break;
    }
    return 0;
}
