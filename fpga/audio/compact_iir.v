module compact_iir #(
parameter integer NOISE=0,
parameter integer LANES=123,
parameter integer AB=7,
parameter PARAM_FILE="modal_compact.mem",
parameter GAIN_FILE="modal_gain18.mem",
parameter integer TAIL_HOLD_SCALE_SHIFT=0 // 正常使用为0，仅供测试缩短自然尾音时长
)(
input wire clk,rst_n,start,
input wire [287:0] events,
input wire [15:0] valid,latest,
input wire signed [23:0] white_now,white_delay2,
output wire [AB-1:0] envelope_address,
input wire [24:0] envelope_data,
output reg busy,done,
output reg signed [39:0] sum,
output reg overflow
);
`include "compact_math.vh"
(* rom_style="block" *) reg [108:0] params[0:(1<<AB)-1]; // 固定读端；每条109位，不复制每个worker的参数ROM。
(* ram_style="block" *) reg [47:0] states[0:(1<<AB)-1]; // 仅y1/y2两个24位状态，一个读端和一个写端。
(* rom_style="block" *) reg [17:0] gainrom[0:(1<<(AB+5))-1];
reg [108:0] pq;
wire scan_start;
wire [16:0] tail_gain_read;
reg [16:0] tail_gain0;
generate
    if(NOISE) begin : g_noise_unchanged
        assign scan_start=start; // 噪声模块保持原算法、时序和资源路径
        assign tail_gain_read=17'd65536;
    end else begin : g_modal_tail
        modal_tail_control #(.HOLD_SCALE_SHIFT(TAIL_HOLD_SCALE_SHIFT)) tail (
            .clk(clk),.rst_n(rst_n),.start(start),.events(events),.valid(valid),
            .read_drum(pq[99:96]),.read_gain(tail_gain_read),.done(scan_start)
        );
    end
endgenerate
reg [LANES-1:0] initialized;
reg issuing;reg [AB-1:0] issue_lane;
reg [10:0] pipe_valid;
reg [AB-1:0] tag0,tag1,tag2,tag3,tag4,tag5,tag6,tag7,tag8,tag9;
reg [47:0] sq;
reg signed [23:0] b0,a1,a2,y1,y2;
reg [17:0] gainq;reg hit;
wire matched;wire [4:0] velocity;
reg signed [48:0] m0;
reg signed [47:0] m1,m2;
reg signed [49:0] pair_sum,total;
reg signed [47:0] m2_delay;
reg signed [23:0] filtered;
reg signed [47:0] norm_product,weighted_product;
reg signed [23:0] normalized;
reg signed [39:0] contribution;
reg signed [39:0] accumulator;
reg [23:0] norm1,norm2,norm3,norm4,norm5;
reg [23:0] previous1,previous2,previous3,previous4,previous5;
reg [23:0] env2,env3,env4,env5,env6,env7;
wire signed [24:0] difference=$signed({white_now[23],white_now})-$signed({white_delay2[23],white_delay2});
wire signed [24:0] excitation=NOISE?difference:$signed({7'd0,(hit?gainq:18'd0)});
wire signed [49:0] filtered_wide=round22(total);
wire signed [49:0] normalized_wide=round18(norm_product);
assign envelope_address=tag0;
compact_event_match match(.events(events),.valid(valid),.latest(latest),.retrigger_only(1'b0),.drum(pq[99:96]),.delay_samples(pq[108:100]),.found(matched),.velocity(velocity));
initial begin $readmemh(PARAM_FILE,params);if(!NOISE)$readmemh(GAIN_FILE,gainrom);end
always @(posedge clk) begin
    if(issuing) begin pq<=params[issue_lane];sq<=states[issue_lane];end
    if(pipe_valid[0]) begin
        b0<=pq[23:0];a1<=pq[47:24];a2<=pq[71:48];norm1<=pq[95:72];
        y1<=(initialized[tag0] && (NOISE || tail_gain_read!=0))?sq[23:0]:24'd0;
        y2<=(initialized[tag0] && (NOISE || tail_gain_read!=0))?sq[47:24]:24'd0;
        previous1<=(initialized[tag0] && (NOISE || tail_gain_read!=0))?sq[23:0]:24'd0;
        tail_gain0<=tail_gain_read; // 增益随支路数据传递，不要求三个引擎同拍完成
        if(!NOISE)gainq<=gainrom[{tag0,velocity}];hit<=matched && (NOISE || tail_gain_read!=0);
    end
    if(pipe_valid[1])begin
        m0<=excitation*b0;m1<=y1*a1;m2<=y2*a2; // 三个乘法器跨全部通路逐拍复用，不是每路例化。
        norm2<=norm1;previous2<=previous1;env2<=NOISE?envelope_data[23:0]:{7'd0,tail_gain0};
    end
    if(pipe_valid[2])begin pair_sum<=$signed(m0)-$signed(m1);m2_delay<=m2;norm3<=norm2;previous3<=previous2;env3<=env2;end
    if(pipe_valid[3])begin total<=pair_sum-$signed(m2_delay);norm4<=norm3;previous4<=previous3;env4<=env3;end
    if(pipe_valid[4])begin filtered<=sat24(filtered_wide);norm5<=norm4;previous5<=previous4;env5<=env4;end
    if(pipe_valid[5])begin
        states[tag5]<=(NOISE || env5!=0)?{previous5,filtered}:48'd0; // 淡出归零时在原RAM写口同时清除y1/y2，不增加BRAM端口
        norm_product<=filtered*$signed(norm5);env6<=env5; // 保留原归一化乘法和对应增益流水
    end
    if(pipe_valid[6])begin normalized<=sat24(normalized_wide);env7<=env6;end
    if(pipe_valid[7])begin
        weighted_product<=normalized*$signed(env7); // 噪声仍是原包络；共振增加一个跨123路复用的淡出乘法流水
    end
    if(pipe_valid[8]) begin
        if(NOISE) contribution<=round22(weighted_product);
        else contribution<=(weighted_product>>>16)+((weighted_product[15] && (!weighted_product[47] || (|weighted_product[14:0])))?40'sd1:40'sd0); // Q1.16淡出增益恢复尺度，增益1时与原结果位精确一致
    end
end
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin issuing<=0;issue_lane<=0;pipe_valid<=0;initialized<=0;busy<=0;done<=0;sum<=0;accumulator<=0;overflow<=0;tag0<=0;tag1<=0;tag2<=0;tag3<=0;tag4<=0;tag5<=0;tag6<=0;tag7<=0;tag8<=0;tag9<=0;end
    else begin
        done<=0;pipe_valid<={pipe_valid[9:0],issuing};
        tag0<=issue_lane;tag1<=tag0;tag2<=tag1;tag3<=tag2;tag4<=tag3;tag5<=tag4;tag6<=tag5;tag7<=tag6;tag8<=tag7;tag9<=tag8;
        if(start)begin busy<=1;accumulator<=0;end
        if(scan_start)begin issuing<=1;issue_lane<=0;end
        else if(issuing)begin if(issue_lane==LANES-1)issuing<=0;else issue_lane<=issue_lane+1'b1;end
        if(pipe_valid[5]) initialized[tag5]<=1;
        if(pipe_valid[4] && (filtered_wide>8388607 || filtered_wide < -8388608))overflow<=1;
        if(pipe_valid[6] && (normalized_wide>8388607 || normalized_wide < -8388608))overflow<=1;
        if(pipe_valid[9])begin
            accumulator<=accumulator+contribution;
            if(tag9==LANES-1)begin sum<=accumulator+contribution;done<=1;busy<=0;end
        end
    end
end
endmodule
