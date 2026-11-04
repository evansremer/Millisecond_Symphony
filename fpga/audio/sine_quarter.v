// Exact reconstruction of the original 2048 integer samples.
// One synchronous ROM read, held when disabled, same latency as full table.
module sine_quarter #(parameter FILE="sine_quarter.mem")(
 input clk,enable,input [10:0] address,output signed [15:0] sample
);
 (* rom_style="block" *) reg [14:0] magnitude[0:512];
 reg [14:0] q;reg negative;
 wire [9:0] folded=address[9] ? 10'd512-{1'b0,address[8:0]} : {1'b0,address[8:0]};
 initial $readmemh(FILE,magnitude);
 always @(posedge clk)if(enable)begin q<=magnitude[folded];negative<=address[10];end
 assign sample=negative ? -$signed({1'b0,q}) : $signed({1'b0,q});
endmodule
