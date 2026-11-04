create_clock -name sys_clk -period 20 [get_ports {sys_clk}]

// Start hardware validation at 100 kHz JTAG. Constraint allows up to 1 MHz.
create_clock -name cpu_jtag_tck -period 1000 [get_ports {cpu_jtag_tck}]


# u_usb1: only first-stage synchronizers and handshake-held mailbox payload.
set_false_path -to [get_pins {u_usb/u_usb1/bridge/req_meta*/D u_usb/u_usb1/bridge/ack_meta*/D u_usb/u_usb1/bridge/diag_meta*/D}]
set_max_delay 15 -from [get_pins {u_usb/u_usb1/bridge/request_addr*/Q u_usb/u_usb1/bridge/request_data*/Q u_usb/u_usb1/bridge/request_write*/Q}] -to [get_pins {u_usb/u_usb1/bridge/usb_addr*/D u_usb/u_usb1/bridge/usb_data*/D u_usb/u_usb1/bridge/usb_write*/D}]
set_false_path -hold -from [get_pins {u_usb/u_usb1/bridge/request_addr*/Q u_usb/u_usb1/bridge/request_data*/Q u_usb/u_usb1/bridge/request_write*/Q}] -to [get_pins {u_usb/u_usb1/bridge/usb_addr*/D u_usb/u_usb1/bridge/usb_data*/D u_usb/u_usb1/bridge/usb_write*/D}]
set_max_delay 15 -from [get_pins {u_usb/u_usb1/bridge/response_data*/Q u_usb/u_usb1/bridge/response_error*/Q}] -to [get_pins {u_usb/u_usb1/bridge/prdata*/D u_usb/u_usb1/bridge/pslverr*/D}]
set_false_path -hold -from [get_pins {u_usb/u_usb1/bridge/response_data*/Q u_usb/u_usb1/bridge/response_error*/Q}] -to [get_pins {u_usb/u_usb1/bridge/prdata*/D u_usb/u_usb1/bridge/pslverr*/D}]

# u_usb2: only first-stage synchronizers and handshake-held mailbox payload.
set_false_path -to [get_pins {u_usb/u_usb2/bridge/req_meta*/D u_usb/u_usb2/bridge/ack_meta*/D u_usb/u_usb2/bridge/diag_meta*/D}]
set_max_delay 15 -from [get_pins {u_usb/u_usb2/bridge/request_addr*/Q u_usb/u_usb2/bridge/request_data*/Q u_usb/u_usb2/bridge/request_write*/Q}] -to [get_pins {u_usb/u_usb2/bridge/usb_addr*/D u_usb/u_usb2/bridge/usb_data*/D u_usb/u_usb2/bridge/usb_write*/D}]
set_false_path -hold -from [get_pins {u_usb/u_usb2/bridge/request_addr*/Q u_usb/u_usb2/bridge/request_data*/Q u_usb/u_usb2/bridge/request_write*/Q}] -to [get_pins {u_usb/u_usb2/bridge/usb_addr*/D u_usb/u_usb2/bridge/usb_data*/D u_usb/u_usb2/bridge/usb_write*/D}]
set_max_delay 15 -from [get_pins {u_usb/u_usb2/bridge/response_data*/Q u_usb/u_usb2/bridge/response_error*/Q}] -to [get_pins {u_usb/u_usb2/bridge/prdata*/D u_usb/u_usb2/bridge/pslverr*/D}]
set_false_path -hold -from [get_pins {u_usb/u_usb2/bridge/response_data*/Q u_usb/u_usb2/bridge/response_error*/Q}] -to [get_pins {u_usb/u_usb2/bridge/prdata*/D u_usb/u_usb2/bridge/pslverr*/D}]

create_clock -name disp_pix_clk -period 13.953 [get_pins {u_audio_board/u_pll_disp/u_pll/CLKOUT0}]
create_clock -name disp_ser_clk -period 2.791 [get_pins {u_audio_board/u_pll_disp/u_pll/CLKOUT1}]
create_clock -name audio_core_clk -period 20.345 [get_pins {u_audio_board/u_pll_audio/u_pll/PLL_inst/CLKOUT0}]
# Independently synchronized pointer CDC; only first stage has a false path.
set_false_path -to [get_pins {u_audio_events/rm*/D u_audio_events/wm*/D}]
# Event payload crosses through a dual-clock block RAM; its output is clocked
# by audio_clock. Only Gray-coded pointers cross between ordinary registers.
set_false_path -from [get_ports {sys_rst_n}]

# Theremin toggle mailboxes: only the first synchronizer stages are asynchronous.
set_false_path -to [get_pins {u_theremin/ack_meta*/D u_theremin/request_meta*/D u_theremin/ui_ack_meta*/D u_theremin/ui_request_meta*/D}]
set_max_delay 15 -from [get_pins {u_theremin/held_step*/Q u_theremin/held_gain*/Q u_theremin/held_mix*/Q}] -to [get_pins {u_theremin/audio_step*/D u_theremin/audio_gain*/D u_theremin/audio_mix*/D}]
set_false_path -hold -from [get_pins {u_theremin/held_step*/Q u_theremin/held_gain*/Q u_theremin/held_mix*/Q}] -to [get_pins {u_theremin/audio_step*/D u_theremin/audio_gain*/D u_theremin/audio_mix*/D}]
set_max_delay 15 -from [get_pins {u_theremin/ui_held*/Q}] -to [get_pins {u_theremin/ui_snapshot*/D}]
set_false_path -hold -from [get_pins {u_theremin/ui_held*/Q}] -to [get_pins {u_theremin/ui_snapshot*/D}]

# USB-A touch: synchronized request/ACK, held payload constrained below one cycle.
set_false_path -to [get_pins {u_touch_ui_cdc/ack_meta*/D u_touch_ui_cdc/request_meta*/D u_touch_diag_cdc/ack_meta*/D u_touch_diag_cdc/request_meta*/D}]
set_max_delay 12 -from [get_pins {u_touch_ui_cdc/held*/Q}] -to [get_pins {u_touch_ui_cdc/snapshot*/D}]
set_false_path -hold -from [get_pins {u_touch_ui_cdc/held*/Q}] -to [get_pins {u_touch_ui_cdc/snapshot*/D}]
set_max_delay 12 -from [get_pins {u_touch_diag_cdc/held*/Q}] -to [get_pins {u_touch_diag_cdc/snapshot*/D}]
set_false_path -hold -from [get_pins {u_touch_diag_cdc/held*/Q}] -to [get_pins {u_touch_diag_cdc/snapshot*/D}]

# Asynchronous USB wire inputs enter only these first-stage PHY registers.
set_false_path -from [get_ports {usba_dp usba_dn}] -to [get_pins {u_usba_touch/phy/rx_dp_ms*/D u_usba_touch/phy/rx_dn_ms*/D u_usba_touch/phy/rxd_ms*/D}]

# These flops are the asynchronous assertion/synchronous deassertion reset
# synchronizers themselves. Their outputs to functional reset pins stay timed.
set_false_path -to [get_pins {u_touch_ui_cdc/source_reset_sync*/CLEAR u_touch_ui_cdc/sink_reset_sync*/CLEAR u_touch_diag_cdc/source_reset_sync*/CLEAR u_touch_diag_cdc/sink_reset_sync*/CLEAR}]

# Console CDC: only first-stage synchronizers; ordinary audio/display paths
# remain timed. Held buses cannot be rewritten until the destination ACKs.
set_false_path -to [get_pins {u_console/config_cdc/rs_0*/D u_console/config_cdc/as_0*/D u_console/ui_ack_sync_0*/D u_console/publish_sync_0*/D u_console/stop_sync_0*/D u_console/overflow_sync_0*/D u_console/stop_aclk_0*/D}]
set_false_path -to [get_pins {u_console/touch_events/rm*/D u_console/touch_events/wm*/D}]
set_max_delay 12 -from [get_pins {u_console/config_cdc/held*/Q u_console/config_cdc/seq_counter*/Q}] -to [get_pins {u_console/config_cdc/data*/D u_console/config_cdc/applied_seq*/D}]
set_false_path -hold -from [get_pins {u_console/config_cdc/held*/Q u_console/config_cdc/seq_counter*/Q}] -to [get_pins {u_console/config_cdc/data*/D u_console/config_cdc/applied_seq*/D}]
set_max_delay 12 -from [get_pins {u_console/ui_held*/Q}] -to [get_pins {u_console/display_state*/D}]
set_false_path -hold -from [get_pins {u_console/ui_held*/Q}] -to [get_pins {u_console/display_state*/D}]
set_false_path -to [get_pins {u_console/seq_cdc/ack_meta*/D u_console/seq_cdc/request_meta*/D u_console/status_cdc/ack_meta*/D u_console/status_cdc/request_meta*/D u_console/latest_cdc/ack_meta*/D u_console/latest_cdc/request_meta*/D}]
set_max_delay 12 -from [get_pins {u_console/seq_cdc/held*/Q u_console/status_cdc/held*/Q u_console/latest_cdc/held*/Q}] -to [get_pins {u_console/seq_cdc/snapshot*/D u_console/status_cdc/snapshot*/D u_console/latest_cdc/snapshot*/D}]
set_false_path -hold -from [get_pins {u_console/seq_cdc/held*/Q u_console/status_cdc/held*/Q u_console/latest_cdc/held*/Q}] -to [get_pins {u_console/seq_cdc/snapshot*/D u_console/status_cdc/snapshot*/D u_console/latest_cdc/snapshot*/D}]
set_false_path -to [get_pins {u_console/seq_cdc/source_reset_sync*/CLEAR u_console/seq_cdc/sink_reset_sync*/CLEAR u_console/status_cdc/source_reset_sync*/CLEAR u_console/status_cdc/sink_reset_sync*/CLEAR u_console/latest_cdc/source_reset_sync*/CLEAR u_console/latest_cdc/sink_reset_sync*/CLEAR}]
# Raw-bin triple bank ownership travels with stable request/ACK metadata.
set_false_path -to [get_pins {u_audio_board/raw_store/ack_sync_0*/D u_audio_board/raw_store/req_sync_0*/D}]
set_max_delay 12 -from [get_pins {u_audio_board/raw_store/published*/Q}] -to [get_pins {u_audio_board/raw_store/active*/D u_audio_board/raw_store/active_held*/D}]
set_false_path -hold -from [get_pins {u_audio_board/raw_store/published*/Q}] -to [get_pins {u_audio_board/raw_store/active*/D u_audio_board/raw_store/active_held*/D}]
set_max_delay 12 -from [get_pins {u_audio_board/raw_store/active_*/Q}] -to [get_pins {u_audio_board/raw_store/write_bank*/D}]
set_false_path -hold -from [get_pins {u_audio_board/raw_store/active_*/Q}] -to [get_pins {u_audio_board/raw_store/write_bank*/D}]

# Report enough paths to expose all remaining clock domains; no exception changes.
# XY observation mailbox: only asynchronous first stages/reset synchronizers.
# Held coordinates are stable until three-stage request synchronization + ACK;
# constrain their physical route below one destination clock, not a blanket CDC.
set_false_path -to [get_pins {u_audio_board/u_lissajous/ack_sync_0*/D u_audio_board/u_lissajous/req_sync_0*/D}]
set_false_path -to [get_pins {u_audio_board/u_lissajous/ar*/CLEAR u_audio_board/u_lissajous/pr*/CLEAR}]
set_max_delay 12 -from [get_pins {u_audio_board/u_lissajous/pair_hold*/Q}] -to [get_pins {u_audio_board/u_lissajous/write_address*/D}]
set_false_path -hold -from [get_pins {u_audio_board/u_lissajous/pair_hold*/Q}] -to [get_pins {u_audio_board/u_lissajous/write_address*/D}]
report_timing -setup -max_paths 2000 -max_common_paths 1

# DDR clocks. No broad clock-group exception is used in this integrated design.
create_clock -name loop_memory_clk -period 2.5 [get_nets {u_loop_ddr/memory_clk}]
create_clock -name loop_ui_clk -period 10 [get_pins {u_loop_ddr/phy/gw3_top/u_ddr_phy_top/fclkdiv/CLKOUT}]
# Only first metastability stages and ACK-held payload crossings are excluded
# or bounded. Audio/UI functional setup and hold paths remain analyzed.
set_false_path -to [get_pins {u_loop_ddr/bridge/ack_meta_0*/D u_loop_ddr/bridge/req_meta_0*/D u_loop_ddr/bridge/fault_meta_0*/D u_loop_ddr/cal_meta_0*/D u_loop_ddr/cal_sys_0*/D u_loop_ddr/failed_audio_0*/D}]
set_max_delay 12 -from [get_pins {u_loop_ddr/bridge/held_*/Q}] -to [get_pins {u_loop_ddr/bridge/active_*/D}]
set_false_path -hold -from [get_pins {u_loop_ddr/bridge/held_*/Q}] -to [get_pins {u_loop_ddr/bridge/active_*/D}]
set_max_delay 12 -from [get_pins {u_loop_ddr/bridge/returned*/Q}] -to [get_pins {u_loop_ddr/bridge/rdata*/D u_loop_ddr/bridge/error*/D}]
set_false_path -hold -from [get_pins {u_loop_ddr/bridge/returned*/Q}] -to [get_pins {u_loop_ddr/bridge/rdata*/D u_loop_ddr/bridge/error*/D}]
set_false_path -to [get_pins {u_loop_apb/mb/rs_0*/D u_loop_apb/mb/as_0*/D u_loop_apb/telemetry/ack_meta*/D u_loop_apb/telemetry/request_meta*/D}]
set_max_delay 12 -from [get_pins {u_loop_apb/mb/held*/Q u_loop_apb/mb/seq_counter*/Q}] -to [get_pins {u_loop_apb/mb/data*/D u_loop_apb/mb/applied_seq*/D}]
set_false_path -hold -from [get_pins {u_loop_apb/mb/held*/Q u_loop_apb/mb/seq_counter*/Q}] -to [get_pins {u_loop_apb/mb/data*/D u_loop_apb/mb/applied_seq*/D}]
set_max_delay 12 -from [get_pins {u_loop_apb/telemetry/held*/Q}] -to [get_pins {u_loop_apb/telemetry/snapshot*/D}]
set_false_path -hold -from [get_pins {u_loop_apb/telemetry/held*/Q}] -to [get_pins {u_loop_apb/telemetry/snapshot*/D}]
set_false_path -to [get_pins {u_loop_apb/telemetry/source_reset_sync*/CLEAR u_loop_apb/telemetry/sink_reset_sync*/CLEAR}]

# Vendor reference declares clk400/clk100/sysclk mutually asynchronous.
# Retain normal data timing and narrow the exception to IP calibration-only
# controls, DLL calibration status, asynchronous startup/reset and the two
# vendor clock-domain control endpoints. These are assumptions of encrypted
# vendor IP, not proof of its internal CDC; stress testing is still required.
set_false_path -from [get_regs {u_loop_ddr/phy/*ddr_rsti_reg*}] -to [get_pins {u_loop_ddr/phy/*u_dqs/RESET u_loop_ddr/phy/*u_oser8_mem/RESET u_loop_ddr/phy/*u_cmd_gen/RESET u_loop_ddr/phy/*u_dqs_gen/RESET u_loop_ddr/phy/*u_ck_gen/RESET u_loop_ddr/phy/*fclkdiv/RESETN u_loop_ddr/phy/*u_ides8_mem/RESET}]
# Same encrypted PHY startup reset, now to the negative-edge calibration
# burst flags. Limit to their asynchronous CLEAR pins; normal Q/D remains timed.
set_false_path -from [get_regs {u_loop_ddr/phy/*ddr_rsti_reg*}] -to [get_pins {u_loop_ddr/phy/*u_ddr_init/*rburst_neg*/CLEAR}]
set_false_path -from [get_regs {u_loop_ddr/phy/*read_rclksel_conf* u_loop_ddr/phy/*hold_gen*hold_i*}] -to [get_pins {u_loop_ddr/phy/*u_dqs/HOLD}]
set_false_path -through [get_pins {u_loop_ddr/phy/gw3_top/u_ddr_phy_top/u_dll/STEP*}] -to [get_regs {u_loop_ddr/phy/gw3_top/u_ddr_phy_top/dll_step_base*}]
set_false_path -from [get_regs {u_loop_ddr/phy/gw3_top/u_ddr_phy_top/u_init_rmove_mod/sys_reset_ch*}] -to [get_regs {u_loop_ddr/phy/gw3_top/u_ddr_phy_top/ddr_sync/recalib_s_0*}]
set_false_path -from [get_regs {u_loop_ddr/phy/gw3_top/u_ddr_phy_top/ddr_init_internal_r*}] -to [get_regs {u_loop_ddr/phy/gw3_top/u_ddr_phy_top/wloadn_3*}]

# BT24 RX is asynchronous; only the first serial synchronizer is excluded.
set_false_path -from [get_ports {bt_rx}] -to [get_pins {u_bt_uart/rx_meta*/D}]
