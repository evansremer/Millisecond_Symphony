# 50 MHz 板载参考时钟
create_clock -name clk_50 -period 20.000 -waveform {0 10.000} [get_ports {clk}]

# 两个 PLL 输出各自定义时钟，避免被当作同源同步时钟分析跨域路径
create_clock -name disp_pix_clk -period 13.953 -waveform {0 6.977} [get_pins {u_pll_disp/u_pll/CLKOUT0}]
create_clock -name disp_ser_clk -period 2.791 -waveform {0 1.395} [get_pins {u_pll_disp/u_pll/CLKOUT1}]
create_clock -name audio_core_clk -period 20.345 -waveform {0 10.172} [get_pins {u_pll_audio/u_pll/PLL_inst/CLKOUT0}]

set_clock_groups -asynchronous -group [get_clocks {clk_50}] -group [get_clocks {audio_core_clk}] -group [get_clocks {disp_pix_clk}] -group [get_clocks {disp_ser_clk}]

# 异步输入：复位与两个按键都经各自时钟域的两级同步器
set_false_path -from [get_ports {rst_n}]
set_false_path -from [get_ports {key[0]}]
set_false_path -from [get_ports {key[1]}]
