module compact_dds (
input wire clk,rst_n,start,
output wire [3:0] envelope_address,
input wire [24:0] envelope_data,
output reg busy,done,
output reg signed [39:0] sum
);
`include "compact_math.vh"
(* rom_style="distributed" *) reg [167:0] params[0:15]; // 只有15条记录，用小ROM，避免宽浅块RAM碎片。
(* ram_style="distributed" *) reg [149:0] states[0:15]; // 6个24位字段加6位过渡计数；固定15通路，没有动态状态池。
reg [14:0] initialized;
reg [4:0] stage;reg [3:0] lane;
reg [167:0] pq;reg [149:0] sq;wire signed [15:0] sine_q;
reg [23:0] phase,modphase,base_step,mod_step,peak_pitch,peak_depth;
reg signed [23:0] pitch,depth,step_pitch,step_depth,alpha_pitch,alpha_depth,norm,gain,weight;
reg [5:0] remaining;reg trigger;
reg signed [23:0] ma,mb;
reg signed [47:0] product;
reg signed [39:0] accumulator;
wire signed [49:0] frequency_q6=$signed({1'b0,base_step,6'd0})+$signed(pitch)+round15(product);
wire signed [49:0] frequency_rounded=(frequency_q6>>>6)+((frequency_q6[5] && (!frequency_q6[49] || (|frequency_q6[4:0])))?50'sd1:50'sd0);
wire [23:0] next_mod_address=modphase+mod_step;
wire [10:0] sine_address=(stage==8)?next_mod_address[23:13]:phase[23:13]; // 先选择地址再读一次ROM，避免两个读语句推断成两份查找表。
sine_quarter u_sine(.clk(clk),.enable(stage==8 || stage==11),.address(sine_address),.sample(sine_q));
assign envelope_address=lane;
initial begin $readmemh("dds_compact.mem",params);end
always @*begin
    ma=0;mb=0;
    case(stage)
    3:begin ma=$signed(peak_pitch)-pitch;mb=24'd87381;end
    5:begin ma=$signed(peak_depth)-depth;mb=24'd87381;end
    9:begin ma=depth;mb={{8{sine_q[15]}},sine_q};end
    12:begin ma=gain;mb=norm;end
    14:begin ma={{8{sine_q[15]}},sine_q};mb=weight;end
    16:begin ma=pitch;mb=alpha_pitch;end
    18:begin ma=depth;mb=alpha_depth;end
    endcase
end
always @(posedge clk)begin
    product<=ma*mb; // 一份24×24乘法器，按阶段复用所有DDS乘法。
    if(stage==1)begin pq<=params[lane];sq<=states[lane];end
    if(stage==20)states[lane]<={remaining,step_depth,step_pitch,depth,pitch,modphase,phase};
end
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin stage<=0;lane<=0;initialized<=0;busy<=0;done<=0;sum<=0;accumulator<=0;phase<=0;modphase<=0;base_step<=0;mod_step<=0;peak_pitch<=0;peak_depth<=0;pitch<=0;depth<=0;step_pitch<=0;step_depth<=0;alpha_pitch<=0;alpha_depth<=0;norm<=0;gain<=0;weight<=0;remaining<=0;trigger<=0;end
    else begin
        done<=0;
        case(stage)
        0:if(start)begin lane<=0;accumulator<=0;busy<=1;stage<=1;end
        1:stage<=2;
        2:begin
            base_step<=pq[23:0];mod_step<=pq[47:24];peak_pitch<=pq[71:48];peak_depth<=pq[95:72];alpha_pitch<=pq[119:96];alpha_depth<=pq[143:120];norm<=pq[167:144];
            phase<=initialized[lane]?sq[23:0]:24'd0;modphase<=initialized[lane]?sq[47:24]:24'd0;
            pitch<=initialized[lane]?sq[71:48]:pq[71:48];depth<=initialized[lane]?sq[95:72]:pq[95:72];
            step_pitch<=initialized[lane]?sq[119:96]:24'd0;step_depth<=initialized[lane]?sq[143:120]:24'd0;remaining<=initialized[lane]?sq[149:144]:6'd0;
            gain<=envelope_data[23:0];trigger<=envelope_data[24];
            if(envelope_data[24])begin
                if(initialized[lane] && envelope_data[23:0]!=0) remaining<=48;
                else begin pitch<=pq[71:48];depth<=pq[95:72];remaining<=0;end
            end
            stage<=(envelope_data==0)?21:3;
        end
        3:stage<=4;
        4:begin if(trigger && remaining!=0)step_pitch<=sat24(round22(product));stage<=5;end
        5:stage<=6;
        6:begin if(trigger && remaining!=0)step_depth<=sat24(round22(product));stage<=7;end
        7:begin
            if(remaining!=0)begin pitch<=(remaining==1)?peak_pitch:pitch+step_pitch;depth<=(remaining==1)?peak_depth:depth+step_depth;remaining<=remaining-1'b1;end
            stage<=8;
        end
        8:begin modphase<=modphase+mod_step;stage<=9;end
        9:stage<=10;
        10:begin phase<=phase+frequency_rounded;stage<=11;end
        11:stage<=12;
        12:stage<=13;
        13:begin weight<=sat24(round22(product));stage<=14;end
        14:stage<=15;
        15:begin accumulator<=accumulator+round15(product);stage<=16;end
        16:stage<=17;
        17:begin if(remaining==0)pitch<=sat24(round22(product));stage<=18;end
        18:stage<=19;
        19:begin if(remaining==0)depth<=sat24(round22(product));stage<=20;end
        20:begin initialized[lane]<=1;stage<=21;end
        21:begin if(lane==14)begin sum<=accumulator;busy<=0;done<=1;stage<=0;end else begin lane<=lane+1'b1;stage<=1;end end
        default:stage<=0;
        endcase
    end
end
endmodule
