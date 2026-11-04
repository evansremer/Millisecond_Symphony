// Request selects are registered mutually exclusive address decodes.
// Parallel masked OR avoids a six-peripheral priority chain across the device.
// No new register, bus wait state, peripheral select or side effect.
module apb_read_data_mux(
 input [5:0] selects,
 input [31:0] audio_data,theremin_data,touch_data,console_data,loop_data,usb_data,bt_data,
 output [31:0] data
);
 assign data=({32{selects[0]}} & audio_data) |
             ({32{selects[1]}} & theremin_data) |
             ({32{selects[2]}} & touch_data) |
             ({32{selects[3]}} & console_data) |
             ({32{selects[4]}} & loop_data) |
             ({32{selects[5]}} & bt_data) |
             ({32{~(|selects)}} & usb_data);
endmodule
