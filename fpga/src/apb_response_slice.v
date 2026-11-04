// Registered APB response. Suppress downstream select after capture so an
// always-ready peripheral sees each write once, even during the added wait.
module apb_response_slice(
 input clk,reset_n,psel,penable,input [31:0] slave_data,
 input slave_ready,slave_error,output slave_select,
 output reg [31:0] prdata,output pready,output pslverr
);
 reg response_valid,response_error;
 assign slave_select=psel && !response_valid;
 assign pready=!psel || response_valid;
 assign pslverr=psel && response_valid && response_error;
 always @(posedge clk or negedge reset_n)begin
  if(!reset_n)begin response_valid<=0;response_error<=0;prdata<=0;end
  else if(response_valid || !psel)response_valid<=0;
  else if(penable && slave_ready)begin
   response_valid<=1;prdata<=slave_data;response_error<=slave_error;
  end
 end
endmodule
