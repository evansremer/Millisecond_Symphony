module apb_console(
 input pclk,aclk,uclk,reset_n,input [7:0] paddr,input [31:0] pwdata,
 input [3:0] pstrb,input psel,penable,pwrite,
 output reg [31:0] prdata,output pready,pslverr,
 input sample_ce,input [1023:0] audio_status,
 output [127:0] audio_config,output stop_audio,
 input [27:0] touch,input touch_valid,
 input frame_tick,input [11:0] tile_address,output reg [7:0] tile_data,
 output reg [511:0] display_state,output reg display_ready
);
 localparam [127:0] DEFAULT_CFG={20'd0,2'd0,3'd0,5'd12,5'd20,5'd24,5'd18,2'd0,2'd0,2'd0,5'd16,18'd261888,18'd65536,18'd261888,18'd209664};
 reg [127:0] config_stage;wire cfg_busy;wire [15:0] applied_seq;
 wire wr=psel && penable && pwrite;
 wire rd=psel && penable && !pwrite;
 wire cfg_commit=wr && pstrb==15 && paddr==8'h18 && !cfg_busy && pwdata[0];
 console_mailbox #(.INITIAL(DEFAULT_CFG)) config_cdc(.sclk(pclk),.dclk(aclk),.reset_n(reset_n),
  .staged(config_stage),.commit(cfg_commit),.busy(cfg_busy),.apply(sample_ce),.data(audio_config),.applied_seq(applied_seq));
 wire [15:0] seq_p;wire seq_valid;
 touch_snapshot_cdc #(.WIDTH(16)) seq_cdc(.sclk(aclk),.dclk(pclk),.reset_n(reset_n),.source(applied_seq),.snapshot(seq_p),.valid(seq_valid));
 wire [1023:0] status_p;wire status_valid;reg [1023:0] status_latched;
 touch_snapshot_cdc #(.WIDTH(1024),.CHANGE_ONLY(0)) status_cdc(.sclk(aclk),.dclk(pclk),.reset_n(reset_n),.source(audio_status),.snapshot(status_p),.valid(status_valid));
 wire [31:0] event_data;wire event_empty,event_overflow,stop_toggle;
 console_touch_fifo touch_events(.uclk(uclk),.pclk(pclk),.reset_n(reset_n),.touch(touch),.valid(touch_valid),
  .pop(rd && paddr==8'h0c),.data(event_data),.empty(event_empty),.overflow(event_overflow),.stop_toggle(stop_toggle));
 wire [27:0] latest_touch;
 touch_snapshot_cdc #(.WIDTH(28)) latest_cdc(.sclk(uclk),.dclk(pclk),.reset_n(reset_n),.source(touch),.snapshot(latest_touch),.valid());
 (* ASYNC_REG="TRUE" *) reg [1:0] stop_sync,overflow_sync;
 reg stop_seen,stop_latched;
 (* ASYNC_REG="TRUE" *) reg [1:0] stop_aclk;
 assign stop_audio=stop_aclk[1];
 always @(posedge aclk or negedge reset_n)if(!reset_n)stop_aclk<=0;else stop_aclk<={stop_aclk[0],stop_latched};
 // Two 2048x9 tile banks. Text only, no pixel framebuffer.
 (* syn_ramstyle="block_ram" *)reg [7:0] tiles[0:4095];
 reg [10:0] write_address;reg publish,ui_ack;
 (* ASYNC_REG="TRUE" *) reg [1:0] ui_ack_sync,publish_sync;
 reg active_bank;
 reg [511:0] ui_stage,ui_held;
 wire display_busy=publish!=ui_ack_sync[1];
 reg [4:0] status_index;reg [31:0] status_read;reg status_wait;
 reg freeze_status;
 always @(posedge pclk)status_read<=status_latched[status_index*32+:32];
 assign pready=!(rd && paddr==8'h34 && status_wait);
 wire allowed=(paddr>=8'h40 && paddr<=8'h7c) || (paddr>=8'h80 && paddr<=8'h8c) ||
   paddr==8'h08 || paddr==8'h18 || paddr==8'h20 || paddr==8'h24 || paddr==8'h28 || paddr==8'h30 || paddr==8'h38;
 assign pslverr=wr && (pstrb!=15 || !allowed ||
  (paddr==8'h18 && cfg_busy) || ((paddr==8'h20 || paddr==8'h28) && display_busy));
 always @* case(paddr)
  8'h00:prdata=32'h55490102;
  8'h04:prdata={25'd0,stop_latched,overflow_sync[1],display_ready,event_empty,display_busy,cfg_busy,1'b0};
  8'h08:prdata={31'd0,stop_latched};
  8'h0c:prdata=event_empty?32'h80000000:event_data;
  8'h10:prdata={4'd0,latest_touch};
  8'h14:prdata={16'd0,seq_p};
  8'h30:prdata={27'd0,status_index};
  8'h34:prdata=status_read;
  default:prdata=0;
 endcase
 always @(posedge pclk)if(wr && pstrb==15 && !display_busy && paddr==8'h28)
  tiles[{~publish,write_address}]<=pwdata[7:0];
 always @(posedge pclk or negedge reset_n)begin
  if(!reset_n)begin
   config_stage<=DEFAULT_CFG;ui_stage<=0;ui_held<=0;publish<=0;ui_ack_sync<=0;write_address<=0;
   stop_sync<=0;stop_seen<=0;stop_latched<=0;overflow_sync<=0;status_index<=0;status_latched<=0;status_wait<=0;freeze_status<=0;
  end else begin
   ui_ack_sync<={ui_ack_sync[0],ui_ack};stop_sync<={stop_sync[0],stop_toggle};overflow_sync<={overflow_sync[0],event_overflow};status_wait<=0;
   if(stop_sync[1]!=stop_seen)begin stop_seen<=stop_sync[1];stop_latched<=1;end
   // Separate local write qualification from the wide error-report decoder.
   // The telemetry freeze fanout starts at a register, not the CPU address bus.
   freeze_status<=wr && pstrb==15 && paddr==8'h38;
   if(freeze_status)status_latched<=status_p;
   if(wr && pstrb==15)begin
    if(paddr>=8'h80 && paddr<=8'h8c)config_stage[paddr[3:2]*32+:32]<=pwdata;
    if(paddr>=8'h40 && paddr<=8'h7c)ui_stage[paddr[5:2]*32+:32]<=pwdata;
    case(paddr)
     8'h08:if(stop_sync[1]==stop_seen)stop_latched<=pwdata[0];
     8'h20:if(pwdata[0] && !display_busy)begin ui_held<=ui_stage;publish<=~publish;end
     8'h24:write_address<=pwdata[10:0];
     8'h28:if(!display_busy)write_address<=write_address+1'b1;
     8'h30:begin status_index<=pwdata[4:0];status_wait<=1;end
     8'h38:status_wait<=1;
     default:;
    endcase
   end
  end
 end
 always @(posedge uclk)begin
  if(!reset_n)begin publish_sync<=0;ui_ack<=0;active_bank<=0;display_state<=0;display_ready<=0;tile_data<=0;end
  else begin
   publish_sync<={publish_sync[0],publish};
   if(frame_tick && publish_sync[1]!=ui_ack)begin
    active_bank<=publish_sync[1];display_state<=ui_held;ui_ack<=publish_sync[1];display_ready<=1;
   end
   tile_data<=tiles[{active_bank,tile_address[10:0]}];
  end
 end
endmodule
