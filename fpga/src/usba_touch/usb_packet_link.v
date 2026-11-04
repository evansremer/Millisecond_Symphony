// Single-clock full-speed packet link. SIE license retained in vendor/.
// Direct SIE streaming avoids the legacy 64-byte register FIFO and SOF guard.
module usb_packet_link #(
    parameter FRAME_CLOCKS=48000,
    parameter PACKET_WATCHDOG=96000
) (
    input clk, rst, enable,
    input req, input req_in, input req_ack, input req_data1,
    input [7:0] req_pid, input [6:0] req_addr, input [3:0] req_ep,
    input [15:0] req_len, input [7:0] tx_data,
    output ready, output tx_pop,
    output reg done, output reg [7:0] response,
    output reg [15:0] count, output reg error, timeout,
    output [7:0] rx_data, output rx_push,
    input [7:0] phy_rx_data, input phy_rxvalid, phy_rxactive, phy_rxerror,
    input [1:0] line_state, input phy_txready,
    output [7:0] phy_txdata, output phy_txvalid,
    output reg frame_tick
);
    reg [15:0] phase;
    reg [10:0] frame;
    reg sof_due, pending, is_sof, accepted, start;
    reg [31:0] watchdog;
    reg sticky_error;
    reg [6:0] cooldown;
    reg [7:0] pid;
    reg [6:0] addr;
    reg [3:0] ep;
    reg direction, acknowledge, data1;
    reg [15:0] length;
    wire sie_idle, sie_ack, sie_crc, sie_timeout;
    wire [7:0] sie_response;
    wire [15:0] sie_count;
    wire [6:0] addr_reverse={addr[0],addr[1],addr[2],addr[3],addr[4],addr[5],addr[6]};
    wire [3:0] ep_reverse={ep[0],ep[1],ep[2],ep[3]};
    // Reserve enough time for the largest FS ISO packet, including stuffing.
    // G0 uses only EP0; a single non-SOF request starts early in each frame.
    assign ready=enable && !pending && sie_idle && !sof_due && cooldown==0 && phase<1000;
    usbh_sie #(.USB_CLK_FREQ(48000000)) sie (
        .clk_i(clk),.rst_i(rst || !enable),.start_i(start),
        .in_transfer_i(direction),.sof_transfer_i(is_sof),.resp_expected_i(acknowledge),
        .token_pid_i(pid),.token_dev_i(addr_reverse),.token_ep_i(ep_reverse),
        .data_len_i(length),.data_idx_i(data1),.tx_data_i(tx_data),
        .utmi_txready_i(phy_txready),.utmi_data_i(phy_rx_data),
        .utmi_rxvalid_i(phy_rxvalid),.utmi_rxactive_i(phy_rxactive),.utmi_linestate_i(line_state),
        .ack_o(sie_ack),.tx_pop_o(tx_pop),.rx_data_o(rx_data),.rx_push_o(rx_push),
        .tx_done_o(),.rx_done_o(),.crc_err_o(sie_crc),.timeout_o(sie_timeout),
        .response_o(sie_response),.rx_count_o(sie_count),.idle_o(sie_idle),
        .utmi_data_o(phy_txdata),.utmi_txvalid_o(phy_txvalid));
    always @(posedge clk) begin
        if(rst || !enable) begin
            phase<=0;frame<=0;sof_due<=0;pending<=0;is_sof<=0;
            accepted<=0;start<=0;done<=0;response<=0;count<=0;
            error<=0;timeout<=0;watchdog<=0;sticky_error<=0;cooldown<=0;
            pid<=0;addr<=0;ep<=0;direction<=0;acknowledge<=0;data1<=0;length<=0;
            frame_tick<=0;
        end else begin
            done<=0;frame_tick<=0;
            if(cooldown!=0) cooldown<=cooldown-1'b1;
            if(phase==FRAME_CLOCKS-1) begin phase<=0;sof_due<=1;frame_tick<=1; end
            else phase<=phase+1'b1;
            if(pending) begin
                watchdog<=watchdog+1'b1;
                if(phy_rxactive && phy_rxerror) sticky_error<=1;
                if(sie_ack) begin start<=0;accepted<=1;end
                if(accepted && sie_idle) begin
                    pending<=0;accepted<=0;cooldown<=80;
                    if(!is_sof) begin
                        done<=1;response<=sie_response;count<=sie_count;
                        error<=sie_crc || sticky_error;timeout<=sie_timeout;
                    end
                end else if(watchdog>=PACKET_WATCHDOG) begin
                    // Top-level restarts the bus after a link watchdog.
                    start<=0;pending<=0;accepted<=0;
                    if(!is_sof) begin done<=1;timeout<=1;error<=1;response<=0;count<=0;end
                end
            end else if(sie_idle && sof_due && cooldown==0) begin
                pid<=8'ha5;addr<=frame[6:0];ep<=frame[10:7];
                direction<=0;acknowledge<=0;data1<=0;length<=0;
                is_sof<=1;pending<=1;start<=1;accepted<=0;
                watchdog<=0;sticky_error<=0;sof_due<=0;frame<=frame+1'b1;
            end else if(req && ready) begin
                pid<=req_pid;addr<=req_addr;ep<=req_ep;length<=req_len;
                direction<=req_in;acknowledge<=req_ack;data1<=req_data1;
                is_sof<=0;pending<=1;start<=1;accepted<=0;
                watchdog<=0;sticky_error<=0;
            end
        end
    end
endmodule
