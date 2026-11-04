// Bounded EP0 control transfers. Buffers and validates each received packet
// before publishing bytes. IN data, no-data requests, and bounded OUT data
// up to 64 bytes (including UVC 1.0/1.1 Probe/Commit) are supported.
module usb_ep0_control #(parameter RETRY_CLOCKS=48000, parameter TRANSFER_LIMIT=48000000)(
    input clk,rst,start,
    input [6:0] device_addr, input [6:0] max_packet,
    input [63:0] setup_bytes,
    input [511:0] out_data,
    output reg busy,done,failed, output reg [7:0] failure,
    output reg byte_valid, output reg [7:0] byte_data, output reg [15:0] byte_index,
    output req, output req_in,req_ack,req_data1,
    output [7:0] req_pid,output [6:0] req_addr,output [3:0] req_ep,
    output [15:0] req_len,output [7:0] tx_data,
    input link_ready,link_done,link_error,link_timeout,
    input [7:0] link_response,rx_data,input [15:0] link_count,
    input rx_push,tx_pop
);
    localparam IDLE=0,LAUNCH=1,WAIT_PACKET=2,CHECK=3,EMIT=4,RETRY=5,FINISH=6;
    reg [2:0] state,stage;
    reg [63:0] setup_q;
    reg [511:0] out_q;
    reg [6:0] addr_q,mps_q;
    reg [15:0] requested,total;
    reg toggle;
    reg [7:0] buffer[0:63];
    reg [6:0] captured,emit_pos,packet_count;
    reg overflow;
    reg [3:0] retries;
    reg [6:0] tx_pos;
    reg [31:0] age,delay_count;
    reg [7:0] result_pid;
    reg [15:0] result_count;
    reg result_error,result_timeout;
    wire [15:0] remaining=requested-total;
    wire [15:0] out_packet_len=(remaining>{9'b0,mps_q})?{9'b0,mps_q}:remaining;
    wire [16:0] received_total={1'b0,total}+{1'b0,result_count};
    assign req=(state==LAUNCH);
    assign req_in=(stage==1 || (stage==2 && (requested==0 || !setup_q[7])));
    assign req_ack=1'b1;
    assign req_data1=(stage==0)?1'b0:((stage==2)?1'b1:toggle);
    assign req_pid=(stage==0)?8'h2d:(req_in?8'h69:8'he1);
    assign req_addr=addr_q;
    assign req_ep=0;
    assign req_len=(stage==0)?16'd8:((stage==3)?out_packet_len:16'd0);
    assign tx_data=(stage==0)?((tx_pos<8)?setup_q[tx_pos*8 +: 8]:8'd0):
                   ((stage==3 && total+tx_pos<64)?out_q[(total+tx_pos)*8 +: 8]:8'd0);
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;stage<=0;setup_q<=0;out_q<=0;addr_q<=0;mps_q<=8;
            requested<=0;total<=0;toggle<=1;captured<=0;emit_pos<=0;
            packet_count<=0;overflow<=0;retries<=0;tx_pos<=0;
            age<=0;delay_count<=0;result_pid<=0;result_count<=0;
            result_error<=0;result_timeout<=0;busy<=0;
            done<=0;failed<=0;failure<=0;byte_valid<=0;byte_data<=0;byte_index<=0;
        end else begin
            done<=0;byte_valid<=0;
            if(busy) age<=age+1'b1;
            if(tx_pop && tx_pos<64) tx_pos<=tx_pos+1'b1;
            if(rx_push && state==WAIT_PACKET && stage==1) begin
                if(captured<64) begin buffer[captured[5:0]]<=rx_data;captured<=captured+1'b1;end
                else overflow<=1;
            end
            case(state)
            IDLE: if(start) begin
                setup_q<=setup_bytes;out_q<=out_data;addr_q<=device_addr;mps_q<=max_packet;
                requested<=setup_bytes[63:48];total<=0;toggle<=1;stage<=0;
                retries<=0;age<=0;busy<=1;failed<=0;failure<=0;
                if((setup_bytes[63:48]>64 && !setup_bytes[7]) ||
                    !(max_packet==8 || max_packet==16 || max_packet==32 || max_packet==64)) begin
                    failed<=1;failure<=8'h08;state<=FINISH;
                end else state<=LAUNCH;
            end
            LAUNCH: if(link_ready) begin
                captured<=0;overflow<=0;tx_pos<=0;state<=WAIT_PACKET;
            end
            WAIT_PACKET: if(link_done) begin
                result_pid<=link_response;result_count<=link_count;
                result_error<=link_error;result_timeout<=link_timeout;state<=CHECK;
            end
            CHECK: begin
                if(result_pid==8'h1e) begin failed<=1;failure<=8'h01;state<=FINISH;end
                else if(result_error || result_timeout || result_pid==8'h5a ||
                    (stage==0 && result_pid!=8'hd2) ||
                    (stage==3 && result_pid!=8'hd2) ||
                    (stage==2 && !req_in && result_pid!=8'hd2) ||
                    (stage==2 && req_in && result_pid!=8'h4b) ||
                    (stage==1 && result_pid!=8'hc3 && result_pid!=8'h4b)) begin
                    if(retries==8) begin
                        failed<=1;failure<=result_timeout?8'h02:(result_error?8'h03:8'h04);state<=FINISH;
                    end else begin retries<=retries+1'b1;delay_count<=0;state<=RETRY;end
                end else if(stage==0) begin
                    retries<=0;stage<=requested==0?2:(setup_q[7]?1:3);state<=LAUNCH;
                end else if(stage==2) begin
                    if(req_in && result_count!=0) begin failed<=1;failure<=8'h09;end
                    state<=FINISH;
                end else if(stage==3) begin
                    total<=total+out_packet_len;toggle<=!toggle;retries<=0;
                    if(total+out_packet_len>=requested) stage<=2;
                    state<=LAUNCH;
                end
                else if(overflow || result_count>mps_q || result_count!=captured) begin
                    failed<=1;failure<=8'h05;state<=FINISH;
                end else if(result_pid!=(toggle?8'h4b:8'hc3)) begin
                    // A retransmitted duplicate was ACKed; do not publish it twice.
                    if(retries==8) begin failed<=1;failure<=8'h06;state<=FINISH;end
                    else begin retries<=retries+1'b1;delay_count<=0;state<=RETRY;end
                end else if(received_total>{1'b0,requested}) begin
                    failed<=1;failure<=8'h05;state<=FINISH;
                end else begin
                    retries<=0;packet_count<=captured;emit_pos<=0;
                    toggle<=!toggle;state<=EMIT;
                end
            end
            EMIT: begin
                if(emit_pos<packet_count) begin
                    byte_valid<=1;byte_data<=buffer[emit_pos[5:0]];
                    byte_index<=total+emit_pos;emit_pos<=emit_pos+1'b1;
                end else begin
                    total<=total+packet_count;
                    if(packet_count<mps_q || total+packet_count>=requested) stage<=2;
                    state<=LAUNCH;
                end
            end
            RETRY: if(delay_count>=RETRY_CLOCKS) state<=LAUNCH;else delay_count<=delay_count+1'b1;
            FINISH: begin done<=1;busy<=0;state<=IDLE;end
            default: state<=IDLE;
            endcase
            if(busy && age>=TRANSFER_LIMIT && state!=FINISH) begin
                failed<=1;failure<=8'h07;state<=FINISH;
            end
        end
    end
endmodule
