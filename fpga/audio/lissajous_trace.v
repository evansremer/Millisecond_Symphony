// Read-only final PCM observer. No path returns to the audio engine.
// Two 128x128 one-bit banks: 32768 bits total, no full-screen framebuffer.
module lissajous_trace(
 input audio_clk,pixel_clk,reset_n,
 input signed [23:0] pcm_left,pcm_right,input pcm_valid,
 input frame_tick,input [13:0] read_address,
 output trace_pixel,output have_frame
);
 (* syn_preserve=1, async_reg="true" *) reg [1:0] ar,pr;
 always @(posedge audio_clk or negedge reset_n)
  if(!reset_n)ar<=0;else ar<={ar[0],1'b1};
 always @(posedge pixel_clk or negedge reset_n)
  if(!reset_n)pr<=0;else pr<={pr[0],1'b1};
 // monitor_pcm_valid accompanies the update of the PCM hold registers.
 // Delay it once so the mailbox captures the newly completed stereo pair.
 reg valid_d,request;
 reg [13:0] pair_hold;
 reg acknowledge;
 (* syn_preserve=1, async_reg="true" *) reg [2:0] ack_sync,req_sync;
 always @(posedge audio_clk or negedge ar[1])begin
  if(!ar[1])begin valid_d<=0;request<=0;pair_hold<=0;ack_sync<=0;end
  else begin
   valid_d<=pcm_valid;ack_sync<={ack_sync[1:0],acknowledge};
   if(valid_d && ack_sync[2]==request)begin
    // X is sign-offset left; invert sign-offset right so positive is up.
    // The full-scale mapping is fixed. Both coordinates belong to one sample.
    pair_hold<={(pcm_right[23:17]^7'h3f),(pcm_left[23:17]^7'h40)};
    request<=~request;
   end
  end
 end
 (* syn_ramstyle="block_ram" *) reg memory0[0:16383];
 (* syn_ramstyle="block_ram" *) reg memory1[0:16383];
 reg front,initialized,clearing,available;
 reg [14:0] init_address;
 reg [13:0] clear_address,write_address;
 reg write0,write1,write_data,read0,read1,front_q,available_q;
 always @(posedge pixel_clk)begin
  if(write0)memory0[write_address]<=write_data;
  if(write1)memory1[write_address]<=write_data;
  read0<=memory0[read_address];read1<=memory1[read_address];
  front_q<=front;available_q<=available;
 end
 assign trace_pixel=available_q && (front_q?read1:read0);
 assign have_frame=available;
 always @(posedge pixel_clk or negedge pr[1])begin
  if(!pr[1])begin
   req_sync<=0;acknowledge<=0;front<=0;initialized<=0;clearing<=0;
   available<=0;init_address<=0;clear_address<=0;
   write0<=0;write1<=0;write_data<=0;write_address<=0;
  end else begin
   req_sync<={req_sync[1:0],request};
   write0<=0;write1<=0;
   // Always drain the observation mailbox, even during clearing. Any samples
   // omitted during ~0.23ms of visual clearing do not stall or alter audio.
   if(req_sync[2]!=acknowledge)acknowledge<=req_sync[2];
   if(!initialized)begin
    write0<=!init_address[14];write1<=init_address[14];
    write_address<=init_address[13:0];write_data<=0;
    if(init_address==15'd32767)initialized<=1;
    else init_address<=init_address+1'b1;
   end else if(clearing)begin
    write0<=front;write1<=!front;write_address<=clear_address;write_data<=0;
    if(clear_address==14'd16383)clearing<=0;
    else clear_address<=clear_address+1'b1;
   end else if(frame_tick)begin
    front<=!front;available<=1;clearing<=1;clear_address<=0;
   end else if(req_sync[2]!=acknowledge)begin
    write0<=front;write1<=!front;write_address<=pair_hold;write_data<=1;
   end
  end
 end
endmodule
