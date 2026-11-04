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
