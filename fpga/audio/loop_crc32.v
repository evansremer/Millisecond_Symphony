// Serial CRC-32/ISO-HDLC, reflected polynomial, 224 payload bits LSB first.
// 224 audio clocks < 4.6 us; no ROM, BSRAM or wide combinational XOR tree.
module loop_crc32(input clk,reset_n,start,input [223:0] data,
 output busy,output reg done,output reg [31:0] result);
 reg [223:0] shift;reg [31:0] crc;reg [7:0] remaining;
 wire [31:0] next_crc=(crc>>1)^((crc[0]^shift[0])?32'hedb88320:32'd0);
 assign busy=remaining!=0;
 always @(posedge clk or negedge reset_n)
 if(!reset_n)begin shift<=0;crc<=0;remaining<=0;done<=0;result<=0;end
 else begin
  done<=0;
  if(start && !busy)begin shift<=data;crc<=32'hffffffff;remaining<=224;end
  else if(busy)begin
   shift<=shift>>1;crc<=next_crc;remaining<=remaining-1'b1;
   if(remaining==1)begin result<=~next_crc;done<=1;end
  end
 end
endmodule
