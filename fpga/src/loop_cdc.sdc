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
set_false_path -from [get_regs {u_loop_ddr/phy/*read_rclksel_conf* u_loop_ddr/phy/*hold_gen*hold_i*}] -to [get_pins {u_loop_ddr/phy/*u_dqs/HOLD}]
set_false_path -through [get_pins {u_loop_ddr/phy/gw3_top/u_ddr_phy_top/u_dll/STEP*}] -to [get_regs {u_loop_ddr/phy/gw3_top/u_ddr_phy_top/dll_step_base*}]
set_false_path -from [get_regs {u_loop_ddr/phy/gw3_top/u_ddr_phy_top/u_init_rmove_mod/sys_reset_ch*}] -to [get_regs {u_loop_ddr/phy/gw3_top/u_ddr_phy_top/ddr_sync/recalib_s_0*}]
set_false_path -from [get_regs {u_loop_ddr/phy/gw3_top/u_ddr_phy_top/ddr_init_internal_r*}] -to [get_regs {u_loop_ddr/phy/gw3_top/u_ddr_phy_top/wloadn_3*}]
