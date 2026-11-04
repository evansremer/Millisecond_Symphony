// G0: enumerate and preserve the actual FS device and configuration bytes.
// No claim of UVC streaming until descriptors and Probe/Commit are implemented.
module usb_camera_probe #(
    parameter MS_CLOCKS=48000, parameter CONFIG_LIMIT=4096,
    parameter PORT_BUDGET_2MA=225,
    // Explicit one-shot diagnostic top only; production default stays guarded.
    // Does not change the physical port rating or measure current.
    parameter DIAGNOSTIC_ACCEPT_500MA=0
)(
    input clk,rst,input [1:0] line_state,
    output reg bus_reset,host_enable,
    output ctrl_start,output [6:0] device_addr,max_packet,
    output [63:0] setup_bytes,
    input ctrl_done,ctrl_failed,input [7:0] ctrl_failure,
    input byte_valid,input [7:0] byte_data,input [15:0] byte_index,
    output reg trace_valid,output reg [31:0] trace_data,
    output reg [7:0] state_code,
    output configured,device_byte_valid,config_byte_valid
);
    localparam WAIT_ATTACH=0,RESET_BUS=1,RECOVER=2,ISSUE=3,WAIT_CTRL=4,
        NEXT=5,ADDRESS_WAIT=6,READY_STATE=7,ERROR_STATE=8,RESTART=9,POWER_BLOCKED=10;
    localparam [7:0] BUDGET_UNITS=PORT_BUDGET_2MA;
    reg [3:0] state;
    reg [2:0] step;
    reg [31:0] timer,heartbeat,disconnect_count,startup;
    reg [6:0] address,mps;
    reg [15:0] config_total,received;
    reg [7:0] config_value,dev_type,dev_length,max_power,attributes;
    reg [63:0] request_bytes;
    reg start_q;
    assign ctrl_start=start_q;
    assign device_addr=address;
    assign max_packet=mps;
    assign setup_bytes=request_bytes;
    assign configured=(state==READY_STATE);
    assign device_byte_valid=byte_valid && state==WAIT_CTRL && step==2;
    assign config_byte_valid=byte_valid && state==WAIT_CTRL && step==4;
    // setup is little endian: bmRequestType,bRequest,wValue,wIndex,wLength.
    always @* begin
        case(step)
        0: request_bytes=64'h0008_0000_0100_0680;
        1: request_bytes=64'h0000_0000_0001_0500;
        2: request_bytes=64'h0012_0000_0100_0680;
        3: request_bytes=64'h0009_0000_0200_0680;
        4: request_bytes={config_total,16'h0000,16'h0200,16'h0680};
        5: request_bytes={16'h0000,16'h0000,8'h00,config_value,16'h0900};
        default: request_bytes=0;
        endcase
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=WAIT_ATTACH;step<=0;timer<=0;heartbeat<=0;disconnect_count<=0;startup<=0;
            address<=0;mps<=8;config_total<=0;received<=0;config_value<=0;max_power<=0;attributes<=0;
            dev_type<=0;dev_length<=0;start_q<=0;bus_reset<=0;host_enable<=0;
            trace_valid<=0;trace_data<=0;state_code<=0;
        end else begin
            trace_valid<=0;start_q<=0;state_code<={1'b0,step,state};
            if(startup<MS_CLOCKS*5000) startup<=startup+1'b1;
            heartbeat<=heartbeat+1'b1;
            if(heartbeat>=MS_CLOCKS*1000) begin
                heartbeat<=0;trace_valid<=1;
                trace_data<={8'h01,state_code,14'b0,line_state};
            end
            if(line_state==0 && !bus_reset) disconnect_count<=disconnect_count+1'b1;
            else disconnect_count<=0;
            if(byte_valid && state==WAIT_CTRL) begin
                trace_valid<=1;trace_data<={(step==4?8'h11:8'h10),byte_index,byte_data};
                received<=byte_index+1'b1;
                if(byte_index==0) dev_length<=byte_data;
                if(byte_index==1) dev_type<=byte_data;
                if(step==0 && byte_index==7) mps<=byte_data[6:0];
                if(step==3 && byte_index==2) config_total[7:0]<=byte_data;
                if(step==3 && byte_index==3) config_total[15:8]<=byte_data;
                if(step==3 && byte_index==5) config_value<=byte_data;
                if(step==3 && byte_index==7) attributes<=byte_data;
                if(step==3 && byte_index==8) max_power<=byte_data;
            end
            case(state)
            WAIT_ATTACH: begin
                bus_reset<=0;host_enable<=0;
                if(line_state==1 && startup>=MS_CLOCKS*5000) begin
                    if(timer>=MS_CLOCKS*100) begin
                        state<=RESET_BUS;timer<=0;bus_reset<=1;
                        trace_valid<=1;trace_data<=32'h02000001;
                    end else timer<=timer+1'b1;
                end else timer<=0;
            end
            RESET_BUS: if(timer>=MS_CLOCKS*20) begin
                timer<=0;bus_reset<=0;host_enable<=1;state<=RECOVER;
                address<=0;mps<=8;step<=0;
            end else timer<=timer+1'b1;
            RECOVER: if(timer>=MS_CLOCKS*10) begin timer<=0;state<=ISSUE;end
                else timer<=timer+1'b1;
            ISSUE: begin
                start_q<=1;received<=0;dev_type<=0;dev_length<=0;state<=WAIT_CTRL;
                trace_valid<=1;trace_data<={8'h02,16'h0000,5'b0,step};
            end
            WAIT_CTRL: if(ctrl_done) begin
                if(ctrl_failed) begin
                    trace_valid<=1;trace_data<={8'he0,5'b0,step,state_code,ctrl_failure};
                    state<=ERROR_STATE;timer<=0;
                end else state<=NEXT;
            end
            NEXT: begin
                if((step==0 && (received!=8 || dev_type!=1 || dev_length!=18 ||
                    !(mps==8 || mps==16 || mps==32 || mps==64))) ||
                    (step==2 && (received!=18 || dev_type!=1)) ||
                    (step==3 && (received!=9 || dev_type!=2 || dev_length!=9 || config_total<9 || config_total>CONFIG_LIMIT || config_value==0)) ||
                    (step==4 && (received!=config_total || dev_type!=2))) begin
                    trace_valid<=1;trace_data<={8'he1,5'b0,step,received};
                    state<=ERROR_STATE;timer<=0;
                end else if(step==4 && max_power>PORT_BUDGET_2MA) begin
                    // Descriptor bMaxPower remains a bus-current declaration,
                    // including for a self-powered configuration. Do not assume
                    // lower consumption from resolution or an idle camera.
                    trace_valid<=1;
                    if(DIAGNOSTIC_ACCEPT_500MA && max_power<=250) begin
                        // E4 explicitly records a declared-budget test exception.
                        // Diagnostic top is bounded; the explicitly selected
                        // live HDMI top supports user-requested continuous use.
                        state<=ISSUE;step<=5;
                        trace_data<={8'he4,attributes,max_power,BUDGET_UNITS};
                    end else begin
                        state<=POWER_BLOCKED;
                        trace_data<={8'he3,attributes,max_power,BUDGET_UNITS};
                    end
                end else if(step==1) begin address<=1;timer<=0;state<=ADDRESS_WAIT;end
                else if(step==5) begin
                    state<=READY_STATE;trace_valid<=1;
                    trace_data<={8'h20,config_total,config_value};
                end else begin step<=step+1'b1;state<=ISSUE;end
            end
            ADDRESS_WAIT: if(timer>=MS_CLOCKS*3) begin step<=2;state<=ISSUE;timer<=0;end
                else timer<=timer+1'b1;
            ERROR_STATE: if(timer>=MS_CLOCKS*2000) begin state<=RESTART;timer<=0;end
                else timer<=timer+1'b1;
            RESTART: begin host_enable<=0;bus_reset<=0;timer<=0;state<=WAIT_ATTACH;end
            READY_STATE: ;
            POWER_BLOCKED: ;
            default: state<=RESTART;
            endcase
            if(host_enable && !bus_reset && disconnect_count>=MS_CLOCKS*3 &&
                state!=RESET_BUS && state!=RECOVER) begin
                state<=RESTART;trace_valid<=1;trace_data<=32'he2000000;
            end
        end
    end
endmodule
