module compact_envelope #(
parameter integer LANES=52,
parameter integer AB=6,
parameter STATE_STYLE=(LANES<=16)?"distributed":"block",
parameter PARAM_STYLE=(LANES<=16)?"distributed":"block",
parameter PARAM_FILE="noise_env.mem",
parameter GAIN_FILE="noise_gain18.mem"
)(
input wire clk,rst_n,start,
input wire [287:0] events,
input wire [15:0] valid,latest,
output reg busy,done,
input wire [AB-1:0] read_lane,
output reg [24:0] read_gain // bit24为本帧重触发；低24位为Q22幅度。
);
`include "compact_math.vh"
(* rom_style=PARAM_STYLE *) reg [68:0] params[0:(1<<AB)-1];
(* rom_style="block" *) reg [17:0] gains[0:(1<<(AB+5))-1];
(* ram_style=STATE_STYLE *) reg [101:0] states[0:(1<<AB)-1]; // E24、步长24、目标24、剩余8、舍入余数22；16深用LUTRAM，64深集中块RAM。
(* ram_style="distributed" *) reg [24:0] frame_gain[0:(1<<AB)-1]; // 小型单帧权重存储，一个写端一个读端，无整帧快照复制。
reg [LANES-1:0] initialized;
reg [3:0] stage;
reg [AB-1:0] lane;
reg [68:0] pq;
reg [101:0] sq;
reg [17:0] gq;
wire found;wire [4:0] velocity;
reg triggered;
reg signed [23:0] e,step,target,alpha,reciprocal;
reg [7:0] remaining;
reg signed [21:0] residue;
reg signed [47:0] product;
wire signed [23:0] old_e=initialized[lane] ? sq[23:0] : 24'sd0;
wire [23:0] peak={2'd0,gq,4'd0};
wire [23:0] target_hit=(old_e>$signed(peak)) ? old_e : peak;
wire [7:0] attack=(old_e>0 && pq[20:13]<48)?8'd48:pq[20:13];
wire signed [49:0] corrected=$signed(product)+$signed(residue);
wire signed [49:0] rounded=round22(corrected);
wire signed [49:0] remainder_value=corrected-(rounded<<<22);
compact_event_match match(.events(events),.valid(valid),.latest(latest),.retrigger_only(1'b1),.drum(pq[3:0]),.delay_samples(pq[12:4]),.found(found),.velocity(velocity));
initial begin $readmemh(PARAM_FILE,params);$readmemh(GAIN_FILE,gains);end
always @(posedge clk) begin
    read_gain<=frame_gain[read_lane];
    if(stage==1) begin pq<=params[lane];sq<=states[lane];end
    if(stage==2) gq<=gains[{lane,velocity}];
    if(stage==4) product<=(triggered && remaining!=0)?($signed(target-e)*reciprocal):(e*alpha);
    if(stage==6) frame_gain[lane]<={triggered,e};
    if(stage==8) states[lane]<={residue,remaining,target,step,e};
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin stage<=0;lane<=0;busy<=0;done<=0;initialized<=0;triggered<=0;e<=0;step<=0;target<=0;alpha<=0;reciprocal<=0;remaining<=0;residue<=0;end
    else begin
        done<=0;
        case(stage)
        0:if(start)begin lane<=0;busy<=1;stage<=1;end
        1:stage<=2;
        2:begin triggered<=found;stage<=3;end
        3:begin
            alpha<=pq[44:21];e<=old_e;
            step<=initialized[lane]?sq[47:24]:24'd0;target<=initialized[lane]?sq[71:48]:24'd0;
            remaining<=initialized[lane]?sq[79:72]:8'd0;residue<=initialized[lane]?sq[101:80]:22'd0;
            if(triggered)begin
                target<=target_hit;remaining<=attack;residue<=0;
                reciprocal<=(old_e>0 && pq[20:13]<48)?24'd87381:pq[68:45];
                if(attack==0) e<=target_hit;
            end
            stage<=4;
        end
        4:stage<=5;
        5:begin if(triggered && remaining!=0)step<=sat24(round22(product));stage<=6;end
        6:begin // 先把本采样的包络提供给发声，再更新下一采样状态。
            if(remaining!=0)begin e<=(remaining==1)?target:e+step;remaining<=remaining-1'b1;residue<=0;end
            else begin e<=sat24(rounded);residue<=remainder_value[21:0];end
            stage<=7;
        end
        7:begin if(e==0)residue<=0;stage<=8;end
        8:begin
            initialized[lane]<=1;
            if(lane==LANES-1)begin busy<=0;done<=1;stage<=0;end
            else begin lane<=lane+1'b1;stage<=1;end
        end
        default:stage<=0;
        endcase
    end
end
endmodule
