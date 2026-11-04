module top (
    input bt_rx,output bt_tx,
    input sys_clk,sys_rst_n, output uart_tx, input uart_rx,
    input tinyf_pitch_rx,tinyf_volume_rx,output tinyf_pitch_tx,tinyf_volume_tx,
    input cpu_jtag_tck,cpu_jtag_tms,cpu_jtag_tdi,cpu_jtag_trst_n,
    output cpu_jtag_tdo, inout usb1_dp,usb1_dn,usb2_dp,usb2_dn,usba_dp,usba_dn,
    input [15:0] ch569_hspi_hd,input ch569_hspi_clk,ch569_hspi_req,ch569_hspi_vld,
    output ch569_hspi_rdy,pcm5102_bck,pcm5102_lrck,pcm5102_din,
    output [14:0] ddr_addr,output [2:0] ddr_bank,
    output ddr_cs,ddr_ras,ddr_cas,ddr_we,ddr_ck,ddr_ck_n,ddr_cke,ddr_odt,ddr_reset_n,
    output [3:0] ddr_dm,inout [31:0] ddr_dq,inout [3:0] ddr_dqs,ddr_dqs_n,
    output tmds_clk_n_0,tmds_clk_p_0,output [2:0] tmds_d_n_0,tmds_d_p_0
);
    wire core_clk,ahb_clk,apb_clk,rtc_clk,unused_clk,core_lock,usb_clk,usb_lock;
    Gowin_PLL u_pll (
        .clkin(sys_clk),.clkout0(unused_clk),.clkout1(core_clk),.clkout2(ahb_clk),
        .clkout3(),.clkout4(rtc_clk),.lock(core_lock),
        .enclk0(1'b1),.enclk1(1'b1),.enclk2(1'b1),.enclk3(1'b0),.enclk4(1'b1)
    );
    Usb_PLL u_usb_pll (
        .clkin(sys_clk),.clkout0(usb_clk),.clkout1(),.clkout2(),.clkout3(),.clkout4(),.lock(usb_lock),
        .enclk0(1'b1),.enclk1(1'b0),.enclk2(1'b0),.enclk3(1'b0),.enclk4(1'b0)
    );
    assign apb_clk=ahb_clk;
    // Keep AE350's proven reset path independent of the added USB PLL.
    wire reset_request_n=sys_rst_n;
    wire soc_reset_n=sys_rst_n;
    wire [31:0] paddr,pwdata,prdata;
    wire [3:0] pstrb;
    wire psel,penable,pwrite,pready,pslverr,pclk,prstn;
    wire uart2_txd,uart2_sensor_route;
    assign uart_tx=uart2_sensor_route?1'b1:uart2_txd;
    assign tinyf_volume_tx=uart2_sensor_route?uart2_txd:1'b1;
    RiscV_AE350_SOC_Top u_soc (
        .TCK_IN(cpu_jtag_tck),.TMS_IN(cpu_jtag_tms),.TRST_IN(cpu_jtag_trst_n),
        .TDI_IN(cpu_jtag_tdi),.TDO_OUT(cpu_jtag_tdo),.TDO_OE(),
        .UART2_TXD(uart2_txd),.UART2_RXD(tinyf_volume_rx),.UART2_RTSN(),
        .UART2_CTSN(1'b0),.UART2_DSRN(1'b0),.UART2_DCDN(1'b0),.UART2_RIN(1'b0),
        .UART2_DTRN(),.UART2_OUT1N(),.UART2_OUT2N(),.GPIO(),
        .UART1_RXD(tinyf_pitch_rx),.UART1_CTSN(1'b0),.UART1_DSRN(1'b0),.UART1_DCDN(1'b0),.UART1_RIN(1'b0),
        .UART1_TXD(tinyf_pitch_tx),.UART1_RTSN(),.UART1_DTRN(),.UART1_OUT1N(),.UART1_OUT2N(),
        .APB_PRDATA(prdata),.APB_PREADY(pready),.APB_PSLVERR(pslverr),
        .APB_PADDR(paddr),.APB_PWDATA(pwdata),.APB_PENABLE(penable),.APB_PSEL(psel),
        .APB_PWRITE(pwrite),.APB_PPROT(),.APB_PSTRB(pstrb),.APB_PCLK(pclk),.APB_PRSTN(prstn),
        .CORE_CLK(core_clk),.DDR_CLK(unused_clk),.AHB_CLK(ahb_clk),.APB_CLK(apb_clk),.RTC_CLK(rtc_clk),
        .POR_RSTN(soc_reset_n),.HW_RSTN(soc_reset_n)
    );
    // APB SETUP captures request and decode once; ACCESS and wait states
    // use only this stable bundle. The AE350 already supplies SETUP cycles.
    wire [31:0] request_addr,request_data;
    wire [3:0] request_strb;
    wire request_write;
    wire [6:0] request_select;
    wire request_loop_commit;
    apb_request_capture u_apb_request(.clk(pclk),.reset_n(prstn),
      .psel(psel),.penable(penable),.paddr(paddr),.pwdata(pwdata),.pstrb(pstrb),.pwrite(pwrite),
      .address(request_addr),.data(request_data),.strb(request_strb),.write(request_write),.selects(request_select),.loop_commit_select(request_loop_commit));
    reg [31:0] touch_data;
    wire [31:0] usb_data,audio_data,midi_event_data;
    wire usb_ready,usb_error,audio_ready,audio_error;
    wire bt_select=request_select[6];
    wire [31:0] bt_data;wire bt_ready,bt_error;
    wire audio_select=request_select[0];
    wire theremin_select=request_select[1];
    wire touch_select=request_select[2];
    wire console_select=request_select[3];
    wire loop_select=request_select[4];
    wire [31:0] loop_data;wire loop_ready,loop_error;
    wire [127:0] loop_command;wire loop_command_valid;wire [511:0] loop_status;wire [191:0] loop_diagnostic;
    wire loop_memory_ready,loop_bridge_fault,loop_request,loop_write,loop_bus_ready,loop_response,loop_bus_error;
    wire [28:0] loop_address;wire [255:0] loop_wdata,loop_rdata;
    wire [31:0] console_data;wire console_ready,console_error;
    wire [127:0] console_config;wire console_stop,console_sample_ce;wire [1023:0] console_status;
    wire [511:0] display_state;wire display_ready,console_frame_tick;
    wire [11:0] console_tile_address;wire [7:0] console_tile_data;
    wire [31:0] theremin_data,theremin_step;
    wire [16:0] theremin_gain,theremin_mix;
    wire theremin_ready,theremin_error,ui_clock,ui_reset_n,ui_theremin_enable;
    wire [6:0] ui_theremin_mix;
    wire [15:0] ui_theremin_config_seq;
    wire audio_clock,audio_reset_n,midi_event_valid,midi_event_ready;
    wire access_active;
    wire [31:0] apb_read_data;
    // SETUP-decoded one-hot terms; do not extend a peripheral priority chain.
    wire apb_slave_ready=(bt_select && bt_ready) | (loop_select && loop_ready) |
      (console_select && console_ready) | touch_select | (theremin_select && theremin_ready) |
      (audio_select && audio_ready) | (request_select[5] && usb_ready);
    wire apb_slave_error=(bt_select && bt_error) | (loop_select && loop_error) |
      (console_select && console_error) | (touch_select && request_write && access_active && penable) |
      (theremin_select && theremin_error) | (audio_select && audio_error) | (request_select[5] && usb_error);
    apb_read_data_mux u_apb_read_data(.selects({bt_select,request_select[4:0]}),
      .audio_data(audio_data),.theremin_data(theremin_data),.touch_data(touch_data),
      .console_data(console_data),.loop_data(loop_data),.usb_data(usb_data),.bt_data(bt_data),.data(apb_read_data));
    apb_response_slice u_apb_response(
      .clk(pclk),.reset_n(prstn),.psel(psel),.penable(penable),
      .slave_data(apb_read_data),
      .slave_ready(apb_slave_ready),.slave_error(apb_slave_error),
      .slave_select(access_active),.prdata(prdata),.pready(pready),.pslverr(pslverr));
    apb_bt_uart u_bt_uart(.clk(pclk),.reset_n(prstn && sys_rst_n),.rx(bt_rx),.tx(bt_tx),
      .paddr(request_addr[7:0]),.pwdata(request_data),.pstrb(request_strb),
      .psel(access_active && bt_select),.penable(penable),.pwrite(request_write),
      .prdata(bt_data),.pready(bt_ready),.pslverr(bt_error));
    apb_audio_events u_audio_events(
      .pclk(pclk),.aclk(audio_clock),.reset_n(prstn && sys_rst_n && audio_reset_n),
      .paddr(request_addr[7:0]),.pwdata(request_data),.pstrb(request_strb),.psel(access_active && audio_select),.penable(penable),.pwrite(request_write),
      .prdata(audio_data),.pready(audio_ready),.pslverr(audio_error),
      .event_data(midi_event_data),.event_valid(midi_event_valid),.event_ready(midi_event_ready));
    apb_theremin u_theremin(
      .pclk(pclk),.aclk(audio_clock),.uiclk(ui_clock),
      .reset_n(prstn && sys_rst_n && audio_reset_n && ui_reset_n),
      .paddr(request_addr[7:0]),.pwdata(request_data),.pstrb(request_strb),
      .psel(access_active && theremin_select),.penable(penable),.pwrite(request_write),
      .prdata(theremin_data),.pready(theremin_ready),.pslverr(theremin_error),
      .ui_enable(ui_theremin_enable),.ui_mix(ui_theremin_mix),.ui_config_seq(ui_theremin_config_seq),
      .uart2_sensor_route(uart2_sensor_route),.audio_step(theremin_step),
      .audio_gain(theremin_gain),.audio_mix(theremin_mix));
    // J18 USB-A screen touch. CH569 is no longer an input source.
    assign ch569_hspi_rdy=1'b0;
    reg [3:0] touch_reset_sync;
    always @(posedge usb_clk or negedge sys_rst_n or negedge usb_lock)
      if(!sys_rst_n || !usb_lock)touch_reset_sync<=0;
      else touch_reset_sync<={touch_reset_sync[2:0],1'b1};
    wire touch_rst=!touch_reset_sync[3];
    wire [2:0] usb_touch_state;
    wire usb_touch_valid,usb_touch_down;
    wire [11:0] usb_touch_x,usb_touch_y;
    wire [191:0] usb_touch_diag,touch_diag;
    wire [27:0] ui_touch;
    wire ui_touch_valid;
    usb_a_touch u_usba_touch(.clk(usb_clk),.rst(touch_rst),
      .usb_dp(usba_dp),.usb_dn(usba_dn),.touch_state(usb_touch_state),
      .touch_valid(usb_touch_valid),.touch_down(usb_touch_down),
      .touch_x(usb_touch_x),.touch_y(usb_touch_y),.diagnostics(usb_touch_diag));
    touch_snapshot_cdc #(.WIDTH(28)) u_touch_ui_cdc(
      .sclk(usb_clk),.dclk(ui_clock),.reset_n(!touch_rst && ui_reset_n),
      .source({usb_touch_state,usb_touch_down,usb_touch_x,usb_touch_y}),
      .snapshot(ui_touch),.valid(ui_touch_valid));
    touch_snapshot_cdc #(.WIDTH(192)) u_touch_diag_cdc(
      .sclk(usb_clk),.dclk(pclk),.reset_n(!touch_rst && prstn),
      .source(usb_touch_diag),.snapshot(touch_diag),.valid());
    always @* case(request_addr[7:0])
      8'h00:touch_data=32'h55540101;
      8'h04:touch_data=touch_diag[31:0];
      8'h08:touch_data=touch_diag[63:32];
      8'h0c:touch_data=touch_diag[95:64];
      8'h10:touch_data=touch_diag[127:96];
      8'h14:touch_data=touch_diag[159:128];
      8'h18:touch_data=touch_diag[191:160];
      default:touch_data=0;
    endcase
    apb_console u_console(.pclk(pclk),.aclk(audio_clock),.uclk(ui_clock),
      .reset_n(prstn && sys_rst_n && audio_reset_n && ui_reset_n),
      .paddr(request_addr[7:0]),.pwdata(request_data),.pstrb(request_strb),.psel(access_active && console_select),.penable(penable),.pwrite(request_write),
      .prdata(console_data),.pready(console_ready),.pslverr(console_error),
      .sample_ce(console_sample_ce),.audio_status(console_status),.audio_config(console_config),.stop_audio(console_stop),
      .touch(ui_touch),.touch_valid(ui_touch_valid),.frame_tick(console_frame_tick),
      .tile_address(console_tile_address),.tile_data(console_tile_data),.display_state(display_state),.display_ready(display_ready));
    apb_loop u_loop_apb(.pclk(pclk),.aclk(audio_clock),.reset_n(prstn && sys_rst_n && audio_reset_n),.sample_ce(console_sample_ce),
      .paddr(request_addr[7:0]),.pwdata(request_data),.pstrb(request_strb),.psel(access_active && loop_select),.penable(penable),.pwrite(request_write),.commit_select(request_loop_commit),
      .prdata(loop_data),.pready(loop_ready),.pslverr(loop_error),.command(loop_command),.command_valid(loop_command_valid),.status(loop_status),.diagnostic(loop_diagnostic));
    loop_ddr_board u_loop_ddr(.sys_clk(sys_clk),.reset_n(sys_rst_n),.aclk(audio_clock),
      .diagnostic_start(loop_command_valid && loop_command[7:0]==11 && loop_status[4:0]==0 && loop_status[7] && loop_memory_ready && loop_bus_ready),.diagnostic_status(loop_diagnostic),
      .request(loop_request),.write(loop_write),.address(loop_address),.wdata(loop_wdata),
      .ready(loop_bus_ready),.response(loop_response),.error(loop_bus_error),.rdata(loop_rdata),.memory_ready(loop_memory_ready),.fault(loop_bridge_fault),
      .ddr_addr(ddr_addr),.ddr_bank(ddr_bank),.ddr_cs(ddr_cs),.ddr_ras(ddr_ras),.ddr_cas(ddr_cas),.ddr_we(ddr_we),
      .ddr_ck(ddr_ck),.ddr_ck_n(ddr_ck_n),.ddr_cke(ddr_cke),.ddr_odt(ddr_odt),.ddr_reset_n(ddr_reset_n),.ddr_dm(ddr_dm),.ddr_dq(ddr_dq),.ddr_dqs(ddr_dqs),.ddr_dqs_n(ddr_dqs_n));
    board_top u_audio_board(
      .loop_command(loop_command),.loop_command_valid(loop_command_valid),.loop_status(loop_status),
      .loop_memory_ready(loop_memory_ready),.loop_bridge_fault(loop_bridge_fault),
      .loop_request(loop_request),.loop_write(loop_write),.loop_address(loop_address),.loop_wdata(loop_wdata),
      .loop_bus_ready(loop_bus_ready),.loop_response(loop_response),.loop_bus_error(loop_bus_error),.loop_rdata(loop_rdata),
      .console_sample_ce(console_sample_ce),.console_config(console_config),.console_stop(console_stop),.console_status(console_status),
      .display_state(display_state),.display_ready(display_ready),.console_frame_tick(console_frame_tick),
      .console_tile_address(console_tile_address),.console_tile_data(console_tile_data),
      .clk(sys_clk),.rst_n(sys_rst_n),.key(2'b11),
      .audio_clock(audio_clock),.audio_reset_n(audio_reset_n),
      .ui_clock(ui_clock),.ui_reset_n(ui_reset_n),
      .ui_theremin_enable(ui_theremin_enable),.ui_theremin_mix(ui_theremin_mix),.ui_theremin_config_seq(ui_theremin_config_seq),
      .theremin_step(theremin_step),.theremin_gain(theremin_gain),.theremin_mix(theremin_mix),
      .midi_event_data(midi_event_data),.midi_event_valid(midi_event_valid),.midi_event_ready(midi_event_ready),
      .touch_state(ui_touch[27:25]),.touch_valid(ui_touch_valid),
      .touch_down(ui_touch[24]),.touch_x(ui_touch[23:12]),.touch_y(ui_touch[11:0]),
      .pcm5102_bck(pcm5102_bck),.pcm5102_lrck(pcm5102_lrck),.pcm5102_din(pcm5102_din),
      .tmds_clk_n_0(tmds_clk_n_0),.tmds_clk_p_0(tmds_clk_p_0),.tmds_d_n_0(tmds_d_n_0),.tmds_d_p_0(tmds_d_p_0));
    dual_usb_host u_usb (
        .pclk(pclk),.uclk(usb_clk),.reset_n(prstn && reset_request_n),
        .paddr(request_addr),.pwdata(request_data),.pstrb(request_strb),.psel(access_active && !audio_select && !theremin_select && !touch_select && !console_select && !loop_select && !bt_select),.penable(penable),.pwrite(request_write),
        .prdata(usb_data),.pready(usb_ready),.pslverr(usb_error),.usb1_dp(usb1_dp),.usb1_dn(usb1_dn),.usb2_dp(usb2_dp),.usb2_dn(usb2_dn)
    );
endmodule
