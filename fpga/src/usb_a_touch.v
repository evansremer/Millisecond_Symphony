// Dedicated J18 full-speed USB HID touch host, derived from the verified
// gesture project. AE350, MIDI and audio remain independent of this USB bus.
module usb_a_touch(input clk,rst,inout usb_dp,usb_dn,
 output reg touch_valid,touch_down,output reg [11:0] touch_x,touch_y,
 output [2:0] touch_state,output [191:0] diagnostics);
    wire bus_reset,enable;
    wire [1:0] line_state;
    wire [7:0] txdata,rxdata;
    wire txvalid,txready,rxvalid,rxactive,rxerror,txdp,txdn,txoen;
    usb_fs_phy phy(.clk_i(clk),.rst_i(rst),.utmi_data_out_i(txdata),.utmi_txvalid_i(txvalid),
        .utmi_op_mode_i(2'b00),.utmi_xcvrselect_i(2'b01),.utmi_termselect_i(1'b0),
        .utmi_dppulldown_i(1'b1),.utmi_dmpulldown_i(1'b1),
        .usb_rx_rcv_i(usb_dp && !usb_dn),.usb_rx_dp_i(usb_dp),.usb_rx_dn_i(usb_dn),
        .usb_reset_assert_i(bus_reset),.utmi_data_in_o(rxdata),.utmi_txready_o(txready),
        .utmi_rxvalid_o(rxvalid),.utmi_rxactive_o(rxactive),.utmi_rxerror_o(rxerror),
        .utmi_linestate_o(line_state),.usb_tx_dp_o(txdp),.usb_tx_dn_o(txdn),
        .usb_tx_oen_o(txoen),.usb_reset_detect_o(),.usb_en_o());
    assign usb_dp=txoen?1'bz:txdp;
    assign usb_dn=txoen?1'bz:txdn;
    wire enum_start,ctrl_done,ctrl_failed,byte_valid;
    wire [7:0] ctrl_failure,byte_data,state_code;
    wire [15:0] byte_index;
    wire [6:0] device_addr,mps;
    wire [63:0] enum_setup; wire configured,config_valid,device_valid;
    wire enum_trace_valid;wire [31:0] enum_trace_data;
    usb_camera_probe probe(.clk(clk),.rst(rst),.line_state(line_state),.bus_reset(bus_reset),
        .host_enable(enable),.ctrl_start(enum_start),.device_addr(device_addr),.max_packet(mps),
        .setup_bytes(enum_setup),.ctrl_done(ctrl_done),.ctrl_failed(ctrl_failed),.ctrl_failure(ctrl_failure),
        .byte_valid(byte_valid),.byte_data(byte_data),.byte_index(byte_index),
        .trace_valid(enum_trace_valid),.trace_data(enum_trace_data),.state_code(state_code),
        .configured(configured),.device_byte_valid(device_valid),.config_byte_valid(config_valid));
    wire req,req_in,req_ack,req_data1,link_ready,link_done,link_error,link_timeout,rx_push,tx_pop;
    wire [7:0] req_pid,control_txdata,link_response,packet_rxdata;
    wire [6:0] req_addr;wire [3:0] req_ep;
    wire [15:0] req_len,link_count;
    wire hid_start,hid_poll,hid_req,hid_toggle,hid_trace_valid,trace_ready;
    wire [3:0] hid_ep;wire [63:0] hid_setup;wire [31:0] hid_trace_data;wire [7:0] hid_status;
    wire frame_tick;wire [23:0] hid_packets,hid_naks,hid_errors,hid_duplicates;
    usb_hid_probe #(.MIN_POLL_MS(1)) hid(.clk(clk),.rst(rst || !enable),.configured(configured),
      .config_valid(config_valid),.byte_index(byte_index),.byte_data(byte_data),
      .ctrl_start(hid_start),.setup_bytes(hid_setup),.ctrl_done(ctrl_done),.ctrl_failed(ctrl_failed),
      .byte_valid(byte_valid),.ctrl_failure(ctrl_failure),.frame_tick(frame_tick),
      .link_ready(link_ready && hid_poll),.link_done(link_done && hid_poll),
      .link_error(link_error),.link_timeout(link_timeout),.link_response(link_response),
      .rx_data(packet_rxdata),.link_count(link_count),.rx_push(rx_push && hid_poll),
      .req(hid_req),.polling(hid_poll),.endpoint(hid_ep),.toggle_value(hid_toggle),
      .trace_ready(trace_ready),.trace_valid(hid_trace_valid),.trace_data(hid_trace_data),.status(hid_status),.packet_count(hid_packets),.nak_count(hid_naks),.error_count(hid_errors),.duplicate_count(hid_duplicates));
    wire ctrl_start=configured?hid_start:enum_start;
    wire [63:0] setup_bytes=configured?hid_setup:enum_setup;
    usb_ep0_control control(.clk(clk),.rst(rst || !enable),.start(ctrl_start),
        .device_addr(device_addr),.max_packet(mps),.setup_bytes(setup_bytes),.out_data(512'd0),
        .busy(),.done(ctrl_done),.failed(ctrl_failed),.failure(ctrl_failure),
        .byte_valid(byte_valid),.byte_data(byte_data),.byte_index(byte_index),
        .req(req),.req_in(req_in),.req_ack(req_ack),.req_data1(req_data1),
        .req_pid(req_pid),.req_addr(req_addr),.req_ep(req_ep),.req_len(req_len),.tx_data(control_txdata),
        .link_ready(link_ready && !hid_poll),.link_done(link_done && !hid_poll),.link_error(link_error),.link_timeout(link_timeout),
        .link_response(link_response),.link_count(link_count),.rx_data(packet_rxdata),.rx_push(rx_push && !hid_poll),.tx_pop(tx_pop && !hid_poll));
    usb_packet_link link(.clk(clk),.rst(rst),.enable(enable),
        .req(hid_poll?hid_req:req),.req_in(hid_poll?1'b1:req_in),.req_ack(hid_poll?1'b1:req_ack),.req_data1(hid_poll?hid_toggle:req_data1),
        .req_pid(hid_poll?8'h69:req_pid),.req_addr(hid_poll?7'd1:req_addr),.req_ep(hid_poll?hid_ep:req_ep),.req_len(hid_poll?16'd0:req_len),.tx_data(control_txdata),
        .ready(link_ready),.done(link_done),.response(link_response),.count(link_count),
        .error(link_error),.timeout(link_timeout),.rx_data(packet_rxdata),.rx_push(rx_push),.tx_pop(tx_pop),
        .phy_rx_data(rxdata),.phy_rxvalid(rxvalid),.phy_rxactive(rxactive),.phy_rxerror(rxerror),
        .line_state(line_state),.phy_txready(txready),.phy_txdata(txdata),.phy_txvalid(txvalid),.frame_tick(frame_tick));
    // Accept the exact descriptor captured from the attached touch controller.
    localparam [3639:0] EXPECTED_REPORT=3640'hc002b1010096087500ff260015c509ff0006038502b10a250195550902850281087501957f250015540902815609019510750000ffff270d05c0028148090d0502813109054c4608002602810879460035300911650e551075080026010502810195510908750181079502810195017501250015420902a12209c0028148090d0502813109054c4608002602810879460035300911650e551075080026010502810195510908750181079502810195017501250015420902a12209c0028148090d0502813109054c4608002602810879460035300911650e551075080026010502810195510908750181079502810195017501250015420902a12209c0028148090d0502813109054c4608002602810879460035300911650e551075080026010502810195510908750181079502810195017501250015420902a12209c0028148090d0502813109054c4608002602810879460035300911650e551075080026010502810195510908750181079502810195017501250015420902a12209c0028148090d0502813109054c4608002602810879460035300911650e551075080026010502810195510908750181079502810195017501250015420902a12209018501a104090d05;
    reg report_match,device_match,profile_ok;
    reg [15:0] report_seen;
    always @(posedge clk) begin
      if(rst || !enable) begin report_match<=1;device_match<=1;profile_ok<=0;report_seen<=0;end
      else begin
        if(device_valid) case(byte_index)
          8: if(byte_data!=8'h3d) device_match<=0;
          9: if(byte_data!=8'h41) device_match<=0;
          10: if(byte_data!=8'h07) device_match<=0;
          11: if(byte_data!=8'h21) device_match<=0;
          default: ;
        endcase
        if(byte_valid && hid_status==2) begin
          report_seen<=byte_index+1'b1;
          if(byte_index>=455) report_match<=0;
          else if(byte_data!=EXPECTED_REPORT[byte_index*8+:8]) report_match<=0;
        end
        if(hid_trace_valid && hid_trace_data[31:24]==8'h86)
          profile_ok<=device_match && report_match && report_seen==455 && hid_trace_data[7:0]==0;
      end
    end
    wire decoded_valid,decoded_down;wire [11:0] decoded_x,decoded_y;wire [7:0] contacts;
    wire [23:0] touch_accepted,touch_rejected;
    hid_413d_touch touch_decode(.clk(clk),.rst(rst || !enable),.profile_ok(profile_ok),
      .trace_valid(hid_trace_valid),.trace_data(hid_trace_data),.touch_valid(decoded_valid),
      .touch_down(decoded_down),.touch_x(decoded_x),.touch_y(decoded_y),.contacts(contacts),
      .accepted(touch_accepted),.rejected(touch_rejected));
    assign trace_ready=1'b1;
    wire session_ok=enable && configured && profile_ok && hid_status!=9;
    assign touch_state = session_ok ? 3'd4 :
      (hid_status==9 || state_code[3:0]==8 || state_code[3:0]==10) ? 3'd3 :
      enable ? 3'd2 : 3'd1;
    // A NAK is normal and does not release a stationary finger. Physical detach
    // is filtered by the existing host's 3-ms SE0 detector; loss of its session
    // explicitly publishes a release so the UI cannot remain held after unplug.
    always @(posedge clk) begin
      if(rst) begin touch_valid<=0;touch_down<=0;touch_x<=0;touch_y<=0;end
      else begin
        touch_valid<=0;
        if(!session_ok) begin
          if(touch_down) touch_valid<=1;
          touch_down<=0;
        end else if(decoded_valid) begin
          touch_valid<=1;touch_down<=decoded_down;
          touch_x<=decoded_x;touch_y<=decoded_y;
        end
      end
    end
    assign diagnostics={8'd0,hid_errors,8'd0,hid_packets,
      8'd0,touch_rejected,8'd0,touch_accepted,contacts,touch_x,touch_y,
      8'hA3,5'd0,profile_ok,configured,enable,state_code,hid_status};
endmodule
