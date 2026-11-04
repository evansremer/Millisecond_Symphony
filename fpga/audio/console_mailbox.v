// Stable payload request/ACK. Audio applies only at a real sample boundary.
module console_mailbox #(parameter WIDTH=128, parameter [WIDTH-1:0] INITIAL=0)(
 input sclk,dclk,reset_n,input [WIDTH-1:0] staged,input commit,
 output busy,input apply,output reg [WIDTH-1:0] data,
 output reg [15:0] applied_seq
);
 reg [WIDTH-1:0] held;reg req,ack;reg [15:0] seq_counter;
 (* ASYNC_REG="TRUE" *) reg [1:0] rs,as;
 assign busy=req!=as[1];
 always @(posedge sclk or negedge reset_n)
 if(!reset_n)begin held<=INITIAL;req<=0;as<=0;seq_counter<=0;end
 else begin as<={as[0],ack};if(commit && !busy)begin held<=staged;req<=~req;seq_counter<=seq_counter+1'b1;end end
 always @(posedge dclk or negedge reset_n)
 if(!reset_n)begin data<=INITIAL;rs<=0;ack<=0;applied_seq<=0;end
 else begin rs<={rs[0],req};if(apply && rs[1]!=ack)begin data<=held;ack<=rs[1];applied_seq<=seq_counter;end end
endmodule
