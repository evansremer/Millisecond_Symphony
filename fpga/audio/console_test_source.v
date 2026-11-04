// Existing synth voice slots, not an extra oscillator engine or PCM player.
module console_test_source(
 input [5:0] count,output reg [31:0] key_state,output reg [159:0] notes,velocities
);
 integer i;reg [4:0] n;
 always @*begin
  key_state=0;notes=0;velocities=0;n=0;
  for(i=0;i<32;i=i+1)begin
   if(count==4)case(i)0:n=7;1:n=19;2:n=26;default:n=31;endcase
   else if(count==32)n=i;
   else n=i*2;
   if(i<count && count<=32)key_state[i]=1;
   notes[i*5+:5]=n;velocities[i*5+:5]=5'd8;
  end
 end
endmodule
