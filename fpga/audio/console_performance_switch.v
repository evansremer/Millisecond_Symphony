// Only explicit test/stop actions touch the sources. Page changes never do.
// Fade direct sound out before replacing voices; the reverb engine is not reset.
module console_performance_switch(
 input clk,reset_n,sample_ce,stop,input [5:0] requested,
 output reg [5:0] active,output fading,output reg reseed,output lock_inputs
);
 reg transition;reg [9:0] frames;reg [5:0] target;
 assign fading=transition || stop;
 assign lock_inputs=stop || transition || requested!=0 || active!=0;
 always @(posedge clk or negedge reset_n)begin
  if(!reset_n)begin active<=0;target<=0;frames<=0;transition<=0;reseed<=0;end
  else begin
   reseed<=0;
   if(!transition && requested!=active)begin transition<=1;frames<=0;target<=requested;end
   if(transition && sample_ce)begin
    if(frames==10'd515)begin active<=stop?0:target;transition<=0;reseed<=1;end
    else frames<=frames+1'b1;
   end
  end
 end
endmodule
