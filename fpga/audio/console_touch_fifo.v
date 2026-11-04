// Asynchronous 32-event FIFO, distributed RAM. Coordinates are already rotated.
// Preserve edges; overflowing gestures cancel until a physical release.
module console_touch_fifo #(parameter CONTACT_DIV=71666)(
 input uclk,pclk,reset_n,input [27:0] touch,input valid,
 input pop,output [31:0] data,output empty,output reg overflow,
 output reg stop_toggle
);
 (* syn_ramstyle="distributed_ram",ram_style="distributed" *) reg [31:0] mem[0:31];
 reg [5:0] wp,wg,rp,rg;
 (* ASYNC_REG="TRUE" *)reg [5:0] rm,rs,wm,ws;
 reg [27:0] previous;reg cancel;
 reg [16:0] contact_divider;reg [2:0] contact_count;reg contact_active;
 wire [27:0] filtered_touch={touch[27:25],contact_active,touch[23:0]};
 always @(posedge uclk or negedge reset_n)begin
  if(!reset_n)begin contact_divider<=0;contact_count<=0;contact_active<=0;end
  else begin
   contact_divider<=contact_divider==CONTACT_DIV?0:contact_divider+1'b1;
   if(contact_divider==CONTACT_DIV)begin
    if(touch[24]==contact_active)contact_count<=0;
    else if(contact_count==7)begin contact_active<=touch[24];contact_count<=0;end
    else contact_count<=contact_count+1'b1;
   end
  end
 end
 wire [5:0] nextwp=wp+1'b1;
 wire full=((nextwp>>1)^nextwp)=={~rs[5:4],rs[3:0]};
 assign empty=rg==ws;
 reg [31:0] read_data;
 wire [5:0] read_pointer=rp+((pop && !empty)?6'd1:6'd0);
 always @(posedge pclk)read_data<=mem[read_pointer[4:0]];
 assign data=read_data;
 wire held=contact_active;
 always @(posedge uclk or negedge reset_n)begin
  if(!reset_n)begin wp<=0;wg<=0;rm<=0;rs<=0;previous<=0;overflow<=0;cancel<=0;stop_toggle<=0;end
  else begin
   rm<=rg;rs<=rm;
   if(cancel && !held && !full)cancel<=0;
   if(filtered_touch!=previous)begin
    previous<=filtered_touch;
    if(held && !previous[24] && touch[11:0]<=191 && touch[23:12]>=340)
     stop_toggle<=~stop_toggle;
    if(cancel)begin end
    else if((held || previous[24]) && full)begin overflow<=~overflow;cancel<=1;end
    else if(held || previous[24])begin mem[wp[4:0]]<={3'd0,overflow,filtered_touch};wp<=nextwp;wg<=(nextwp>>1)^nextwp;end
   end
  end
 end
 always @(posedge pclk or negedge reset_n)begin
  if(!reset_n)begin rp<=0;rg<=0;wm<=0;ws<=0;end
  else begin wm<=wg;ws<=wm;if(pop && !empty)begin rp<=rp+1'b1;rg<=((rp+1'b1)>>1)^(rp+1'b1);end end
 end
endmodule
