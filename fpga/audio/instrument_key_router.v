module instrument_key_router(
 input clk,rst_n,sample_ce,input [1:0] instrument_select,input [31:0] key_state,
 output [31:0] piano_keys,horn_keys,synth_keys);
 assign piano_keys=instrument_select==0?key_state:0;
 assign horn_keys=instrument_select==1?key_state:0;
 assign synth_keys=instrument_select==2?key_state:0;
endmodule
