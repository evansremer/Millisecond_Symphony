// Dedicated control mailbox: sensor updates cannot fill the MIDI event FIFO.
// All domains share reset_n. Payloads stay held until a synchronized ACK.
module apb_theremin(
 input pclk,aclk,uiclk,reset_n,
 input [7:0] paddr,input [31:0] pwdata,input [3:0] pstrb,
 input psel,penable,pwrite,
 output reg [31:0] prdata,output pready,pslverr,
 input ui_enable,input [6:0] ui_mix,input [15:0] ui_config_seq,
 output reg uart2_sensor_route,
 output reg [31:0] audio_step,
 output reg [16:0] audio_gain,audio_mix
);
 reg [31:0] staged_step,held_step,feedback;
 reg [16:0] staged_gain,staged_mix,held_gain,held_mix;
 reg request,ack;
 (* ASYNC_REG="TRUE" *) reg ack_meta,ack_sync,request_meta,request_sync;
 wire busy=request!=ack_sync;
 wire access_write=psel && penable && pwrite;
 wire write_address=(paddr==8'h08 || paddr==8'h0c || paddr==8'h10 ||
                     paddr==8'h14 || paddr==8'h18 || paddr==8'h20);
 wire bad_value=((paddr==8'h10 || paddr==8'h14) && pwdata>32'd65536);
 assign pready=1'b1;
 assign pslverr=access_write && (pstrb!=4'hf || !write_address ||
                     bad_value || (paddr==8'h18 && busy));
 reg [31:0] ui_held,ui_snapshot;
 reg ui_request,ui_ack;
 (* ASYNC_REG="TRUE" *) reg ui_ack_meta,ui_ack_sync,ui_request_meta,ui_request_sync;
 wire [31:0] ui_bundle={ui_config_seq,1'b0,ui_mix,7'd0,ui_enable};
 always @(posedge uiclk or negedge reset_n) begin
  if(!reset_n)begin
   ui_held<=32'h00001900;ui_request<=0;ui_ack_meta<=0;ui_ack_sync<=0;
  end else begin
   ui_ack_meta<=ui_ack;ui_ack_sync<=ui_ack_meta;
   if(ui_request==ui_ack_sync && ui_bundle!=ui_held)begin
    ui_held<=ui_bundle;ui_request<=~ui_request;
   end
  end
 end
 always @* begin
  case(paddr)
   8'h00:prdata=32'h54480101;
   8'h04:prdata=ui_snapshot;
   8'h08:prdata={31'd0,uart2_sensor_route};
   8'h0c:prdata=staged_step;
   8'h10:prdata={15'd0,staged_gain};
   8'h14:prdata={15'd0,staged_mix};
   8'h1c:prdata={31'd0,busy};
   8'h20:prdata=feedback;
   default:prdata=0;
  endcase
 end
 always @(posedge pclk or negedge reset_n) begin
  if(!reset_n)begin
   staged_step<=0;staged_gain<=0;staged_mix<=0;
   held_step<=0;held_gain<=0;held_mix<=0;
   request<=0;ack_meta<=0;ack_sync<=0;uart2_sensor_route<=0;feedback<=0;
   ui_request_meta<=0;ui_request_sync<=0;ui_ack<=0;ui_snapshot<=32'h00001900;
  end else begin
   ack_meta<=ack;ack_sync<=ack_meta;
   ui_request_meta<=ui_request;ui_request_sync<=ui_request_meta;
   if(ui_request_sync!=ui_ack)begin
    ui_snapshot<=ui_held;ui_ack<=ui_request_sync;
   end
   if(access_write && !pslverr)case(paddr)
    8'h08:uart2_sensor_route<=pwdata[0];
    8'h0c:staged_step<=pwdata;
    8'h10:staged_gain<=pwdata[16:0];
    8'h14:staged_mix<=pwdata[16:0];
    8'h18:if(pwdata[0])begin
     held_step<=staged_step;held_gain<=staged_gain;held_mix<=staged_mix;
     request<=~request;
    end
    8'h20:feedback<=pwdata;
   endcase
  end
 end
 always @(posedge aclk or negedge reset_n)begin
  if(!reset_n)begin
   request_meta<=0;request_sync<=0;ack<=0;
   audio_step<=0;audio_gain<=0;audio_mix<=0;
  end else begin
   request_meta<=request;request_sync<=request_meta;
   if(request_sync!=ack)begin
    audio_step<=held_step;audio_gain<=held_gain;audio_mix<=held_mix;
    ack<=request_sync;
   end
  end
 end
endmodule
