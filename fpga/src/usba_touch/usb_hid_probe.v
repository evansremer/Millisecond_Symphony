// Diagnostic: first alternate-zero HID interface, report descriptor, interrupt IN.
// Publish only CRC-checked, correctly report_seqd packets. NAK is normal idle.
module usb_hid_probe #(parameter MIN_POLL_MS=100)(
 input clk,rst,configured,config_valid,input [15:0] byte_index,input [7:0] byte_data,
 output reg ctrl_start,output [63:0] setup_bytes,
 input ctrl_done,ctrl_failed,byte_valid,input [7:0] ctrl_failure,
 input frame_tick,link_ready,link_done,link_error,link_timeout,
 input [7:0] link_response,rx_data,input [15:0] link_count,input rx_push,
 output req,output reg polling,output [3:0] endpoint,output toggle_value,
 input trace_ready,output reg trace_valid,output reg [31:0] trace_data,
 output [7:0] status,
 output [23:0] packet_count,nak_count,error_count,duplicate_count
);
 localparam WAIT_CONFIG=0,START_REPORT=1,REPORT=2,POLL_WAIT=3,PACKET=4,
  CHECK=5,HEAD=6,EMIT=7,TAIL=8,FAILED=9;
 reg [3:0] state;
 reg [7:0] pos,dlen,dtype,ifnum,alt,iclass,hid_if,epaddr,interval;
 reg chosen,active_if,malformed,ep_candidate;
 reg [15:0] report_length,ep_mps,report_received;
 reg [7:0] hid_dtype;
 reg [8:0] elapsed;
 reg toggle;
 reg [7:0] buffer[0:63];
 reg [6:0] captured,emit_pos;
 reg overflow;
 reg [15:0] report_seq;
 reg [23:0] packets,naks,errors,duplicates;
 reg [7:0] result_pid;reg [15:0] result_count;
 reg result_error,result_timeout;
 assign status={4'd0,state};
 assign packet_count=packets;assign nak_count=naks;assign error_count=errors;assign duplicate_count=duplicates;
 assign endpoint=epaddr[3:0];assign toggle_value=toggle;
 assign req=state==POLL_WAIT && elapsed>=((interval>MIN_POLL_MS)?interval:MIN_POLL_MS) && trace_ready;
 assign setup_bytes={report_length,8'd0,hid_if,16'h2200,16'h0681};
 always @(posedge clk) begin
  if(rst) begin
   state<=WAIT_CONFIG;pos<=0;dlen<=0;dtype<=0;ifnum<=0;alt<=0;iclass<=0;
   hid_if<=0;epaddr<=0;interval<=0;chosen<=0;active_if<=0;malformed<=0;ep_candidate<=0;
   report_length<=0;ep_mps<=0;hid_dtype<=0;report_received<=0;elapsed<=0;
   toggle<=0;captured<=0;emit_pos<=0;overflow<=0;report_seq<=0;
   packets<=0;naks<=0;errors<=0;duplicates<=0;ctrl_start<=0;polling<=0;
   trace_valid<=0;trace_data<=0;result_pid<=0;result_count<=0;result_error<=0;result_timeout<=0;
  end else begin
   ctrl_start<=0;trace_valid<=0;
   if(config_valid) begin
    if(pos==0) begin dlen<=byte_data;pos<=1;if(byte_data<2) malformed<=1;end
    else begin
     if(pos==1) dtype<=byte_data;
     if(dtype==4) begin
      if(pos==2) ifnum<=byte_data;
      if(pos==3) alt<=byte_data;
      if(pos==5) iclass<=byte_data;
     end
     if(dtype==8'h21 && active_if) begin
      if(pos==6) hid_dtype<=byte_data;
      if(pos==7) report_length[7:0]<=byte_data;
      if(pos==8 && hid_dtype==8'h22) report_length[15:8]<=byte_data;
     end
     if(dtype==5 && active_if && pos==2) begin
      ep_candidate<=epaddr==0 && byte_data[7];
      if(epaddr==0 && byte_data[7]) epaddr<=byte_data;
     end
     // Candidate endpoint is validated at the descriptor end below.
     if(dtype==5 && active_if && ep_candidate) begin
      if(pos==3 && epaddr!=0 && byte_data[1:0]!=3) epaddr<=0;
      if(pos==4 && epaddr!=0) ep_mps[7:0]<=byte_data;
      if(pos==5 && epaddr!=0) ep_mps[15:8]<=byte_data;
      if(pos==6 && epaddr!=0) interval<=byte_data;
     end
     if(pos+1>=dlen) begin
      pos<=0;
      if(dtype==4) begin
       active_if<=!chosen && iclass==3 && alt==0;
       if(!chosen && iclass==3 && alt==0) begin chosen<=1;hid_if<=ifnum;end
      end
     end else pos<=pos+1'b1;
    end
   end
   if(frame_tick && elapsed<511) elapsed<=elapsed+1'b1;
   if(rx_push && state==PACKET) begin
    if(captured<64) begin buffer[captured[5:0]]<=rx_data;captured<=captured+1'b1;end
    else overflow<=1;
   end
   case(state)
   WAIT_CONFIG: if(configured) begin
    if(!chosen || malformed || pos!=0 || report_length==0 || report_length>2048 ||
       epaddr[3:0]==0 || !epaddr[7] || ep_mps==0 || ep_mps>64 || interval==0) begin
     state<=FAILED;trace_valid<=1;trace_data<={8'h8e,hid_if,epaddr,8'h01};
    end else begin state<=START_REPORT;trace_valid<=1;trace_data<={8'h85,hid_if,epaddr,interval};end
   end
   START_REPORT: begin ctrl_start<=1;state<=REPORT;report_received<=0;end
   REPORT: begin
    if(byte_valid) begin
     report_received<=byte_index+1'b1;
     trace_valid<=1;trace_data<={8'h84,byte_index,byte_data};
    end
    if(ctrl_done) begin
     trace_valid<=1;trace_data<={8'h86,report_received,ctrl_failed?ctrl_failure:8'd0};
     if(ctrl_failed || report_received!=report_length) state<=FAILED;
     else begin state<=POLL_WAIT;polling<=1;elapsed<=0;end
    end
   end
   POLL_WAIT: if(req && link_ready) begin captured<=0;overflow<=0;elapsed<=0;state<=PACKET;end
   PACKET: if(link_done) begin
    result_pid<=link_response;result_count<=link_count;
    result_error<=link_error;result_timeout<=link_timeout;state<=CHECK;
   end
   CHECK: begin
    if(result_error || result_timeout) begin errors<=errors+1'b1;state<=POLL_WAIT;
     trace_valid<=1;trace_data<={8'h8e,6'd0,result_error,result_timeout,result_pid,8'h02};end
    else if(result_pid==8'h5a) begin naks<=naks+1'b1;state<=POLL_WAIT;end
    else if(result_pid==8'h1e) begin state<=FAILED;trace_valid<=1;trace_data<=32'h8e000003;end
    else if(overflow || result_count!=captured || result_count>ep_mps ||
      (result_pid!=8'hc3 && result_pid!=8'h4b)) begin
     errors<=errors+1'b1;state<=FAILED;trace_valid<=1;trace_data<=32'h8e000004;
    end else if(result_pid!=(toggle?8'h4b:8'hc3)) begin duplicates<=duplicates+1'b1;state<=POLL_WAIT;end
    else begin toggle<=!toggle;report_seq<=report_seq+1'b1;packets<=packets+1'b1;state<=HEAD;emit_pos<=0;end
   end
   HEAD: if(trace_ready) begin trace_valid<=1;trace_data<={8'h80,report_seq,1'b0,captured};state<=EMIT;end
   EMIT: if(trace_ready) begin
    if(emit_pos<captured) begin trace_valid<=1;trace_data<={8'h81,9'd0,emit_pos,buffer[emit_pos[5:0]]};emit_pos<=emit_pos+1'b1;end
    else state<=TAIL;
   end
   TAIL: if(trace_ready) begin trace_valid<=1;trace_data<={8'h82,report_seq,8'd0};state<=POLL_WAIT;end
   FAILED: ;
   default: state<=FAILED;
   endcase
  end
 end
endmodule
