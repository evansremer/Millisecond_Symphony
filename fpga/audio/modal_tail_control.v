module modal_tail_control #(
    parameter integer HOLD_SCALE_SHIFT = 0 // 正常硬件必须为0；仿真可缩短自然尾音等待，不改变淡出算法
) (
    input wire clk, rst_n, start,
    input wire [287:0] events, // 沿用原调度器事件格式，不新增外部控制接口
    input wire [15:0] valid,
    input wire [3:0] read_drum, // 当前被扫描共振支路所属的鼓号
    output wire [16:0] read_gain, // 无符号Q1.16，65536为1，0为该乐器已经结束
    output reg done // 十件乐器的控制状态准备好后，启动原共振流水线
);
reg busy; // 仅在每个音频帧开始时顺序处理10件乐器
reg [3:0] drum_index;
reg [18:0] remaining [0:9]; // 每件乐器一个19位尾音倒计时，最大10.2秒
reg [16:0] gain [0:9]; // 每件乐器一个17位淡出增益，不按123个共振支路复制
wire new_hit;
wire [4:0] hit_velocity;
integer i;
function [18:0] hold_samples;
    input [3:0] drum;
    reg [18:0] nominal;
    reg [18:0] scaled;
    begin
        case (drum)
            0: nominal=19'd177600; // 高音桶鼓3.7秒
            1: nominal=19'd172800; // 中音桶鼓3.6秒
            2: nominal=19'd201600; // 低音桶鼓4.2秒
            3: nominal=19'd33600; // 底鼓0.7秒
            4: nominal=19'd19200; // 军鼓0.4秒
            5: nominal=19'd19200; // 边击0.4秒
            6: nominal=19'd19200; // 闭镲0.4秒
            7: nominal=19'd52800; // 开镲1.1秒
            8: nominal=19'd379200; // Crash 7.9秒
            9: nominal=19'd489600; // Ride 10.2秒
            default: nominal=19'd19200;
        endcase
        scaled=nominal >> HOLD_SCALE_SHIFT;
        hold_samples=(scaled<19'd512)?19'd512:scaled; // 即使加速仿真也覆盖最大384采样的延迟激励
    end
endfunction
assign read_gain=(read_drum<10)?gain[read_drum]:17'd0;
compact_event_match hit_match (
    .events(events),.valid(valid),.latest(valid),.retrigger_only(1'b0),
    .drum(drum_index),.delay_samples(9'd0),.found(new_hit),.velocity(hit_velocity)
);
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        busy<=0;done<=0;drum_index<=0;
        for(i=0;i<10;i=i+1) begin remaining[i]<=0;gain[i]<=0;end
    end else begin
        done<=0;
        if(start && !busy) begin busy<=1;drum_index<=0;end
        else if(busy) begin
            if(new_hit && hit_velocity!=0) begin
                remaining[drum_index]<=hold_samples(drum_index); // 新击打优先于结束判断，保留原共振状态并重新计时
                if(gain[drum_index]==0) gain[drum_index]<=17'd65536; // 已结束时从清零状态正常起音
                else if(gain[drum_index]>=17'd64512) gain[drum_index]<=17'd65536;
                else gain[drum_index]<=gain[drum_index]+17'd1024; // 淡出期间重击，从当前增益平滑恢复，最多64采样
            end else if(remaining[drum_index]!=0) begin
                remaining[drum_index]<=remaining[drum_index]-1'b1;
                if(gain[drum_index]>=17'd64512) gain[drum_index]<=17'd65536;
                else gain[drum_index]<=gain[drum_index]+17'd1024;
            end else begin
                if(gain[drum_index]>17'd32) gain[drum_index]<=gain[drum_index]-17'd32; // 2048采样线性淡出，48kHz时约42.67ms
                else gain[drum_index]<=0; // 精确归零，不依赖指数衰减是否能舍入到0
            end
            if(drum_index==9) begin busy<=0;done<=1;end
            else drum_index<=drum_index+1'b1;
        end
    end
end
endmodule
