module reverb_stereo_preset #(
    parameter integer MODE_STABLE_CYCLES = 1024 // Mode Stability（同步后模式需稳定的主时钟数），不是机械按键去抖时间
)(
    input wire clk, // System Clock（主时钟），例如98.333MHz
    input wire rst_n, // Reset（异步低电平复位），控制状态复位，BRAM随后顺序清零
    input wire sample_ce, // Sample Enable（单clk输入有效），连接agc_out_valid，不是方波采样时钟
    //总线输入，模式选择
    input wire signed [20:0] in_sample, // Input Sample（21位补码音频），连接agc_out_data
    input wire [1:0] mode_sel, // Mode Select（两位模式），00山谷、01大厅、10房间、11音乐厅
    //输出的音频总线
    output reg signed [20:0] wet_left, // Wet Left（左纯湿声），不包含额外叠加的干声
    output reg signed [20:0] wet_right, // Wet Right（右纯湿声），与左湿声同时更新
    output reg signed [20:0] dry_aligned, // Aligned Dry（本次输入的对齐副本），清零期间仍持续输出
    //调试端口
    output reg out_valid, // Output Valid（三路输出有效），一个clk脉冲，不含下游反压
    output wire busy, // Busy（湿声运算或清零正在进行），清零期间仍接受样本并输出零湿声和原干声
    output reg init_done, // Initialization Done（BRAM清零完成），切换模式清零期间为0
    output reg frame_overrun, // Frame Overrun（正常湿声运算中重复输入），粘滞标志，复位清除
    output reg clip_detected // Clip Detected（状态或输出饱和），粘滞标志，复位清除
);

//常量定义位宽计算
localparam [3:0] ST_CLEAR = 4'd0; // Clear（每clk清零一个BRAM地址）
localparam [3:0] ST_IDLE = 4'd1; // Idle（等待样本或模式切换）
localparam [3:0] ST_COMB_READ = 4'd2; // Comb Read（发起当前梳状支路同步读）
localparam [3:0] ST_COMB_CAPTURE = 4'd3; // Comb Capture（取走上一拍RAM结果）
localparam [3:0] ST_LP_MULTIPLY = 4'd4; // Lowpass Multiply（共享乘法器计算低通更新量）
localparam [3:0] ST_LP_UPDATE = 4'd5; // Lowpass Update（取乘积、更新低通状态）
localparam [3:0] ST_FB_MULTIPLY = 4'd6; // Feedback Multiply（共享乘法器计算反馈量）
localparam [3:0] ST_COMB_WRITE = 4'd7; // Comb Write（写回反馈，累计湿声，推进支路指针）
localparam [3:0] ST_MIX = 4'd8; // Mix（左右各四条支路求和缩放，山谷模式各一条）
localparam [3:0] ST_AP_READ = 4'd9; // Allpass Read（发起当前全通延迟读）
localparam [3:0] ST_AP_CAPTURE = 4'd10; // Allpass Capture（取走全通历史状态）
localparam [3:0] ST_AP_WRITE = 4'd11; // Allpass Write（全通系数固定0.5，以移位加减计算并写回）
localparam [3:0] ST_OUTPUT = 4'd12; // Output（同时发布干声和左右湿声）
localparam [3:0] ST_AP_PREPARE = 4'd13; // Allpass Prepare（先寄存饱和后的写回值），拆开两次加减及范围检查的长组合路径
localparam [3:0] ST_LP_PREPARE = 4'd14; // Lowpass Prepare（选择历史状态并计算差值），先寄存操作数，禁止减法与乘法串联在同一拍
localparam [3:0] ST_FB_PREPARE = 4'd15; // Feedback Prepare（锁存反馈乘法操作数），与低通共用同一组输入寄存器
localparam [4:0] ST_LP_ROUND = 5'd16; // Lowpass Round（独立舍入拍），把乘积舍入与状态加法分开
localparam [4:0] ST_FB_ROUND = 5'd17; // Feedback Round（独立舍入拍），避免舍入、反馈加法及RAM写入形成长路径
localparam integer MODE_COUNT_BITS = (MODE_STABLE_CYCLES <= 1) ? 1 : $clog2(MODE_STABLE_CYCLES); // 稳定判定计数器宽度
localparam integer STATE_FRAC = 4; // State Fraction（内部状态低4位为亚采样码值小数），不是音频时间小数
localparam integer INPUT_SHIFT = 2; // Input Headroom（混响送入增益为1/4），避免高反馈放大造成内部溢出


//乘法器复用状态机
reg [4:0] state; // 当前共享运算调度状态，18种状态需要5位
(* ASYNC_REG = "TRUE" *) reg [1:0] mode_meta; // Mode Synchronizer（第一拍同步），不是多位总线原子传输保证
(* ASYNC_REG = "TRUE" *) reg [1:0] mode_sync; // Mode Synchronizer（第二拍同步）
reg [1:0] mode_candidate; // Mode Candidate（正在判定稳定的候选模式）快照寄存器
reg [MODE_COUNT_BITS-1:0] mode_stable_count; // 连续稳定主时钟计数器
reg [1:0] requested_mode; // Requested Mode（通过稳定判定的新请求）
reg [1:0] active_mode; // Active Mode（当前查表使用的模式），一帧运算期间不变化
reg [14:0] clear_address; // Clear Address（32768点BRAM顺序清零地址）
reg [2:0] comb_index; // Comb Index（当前0～7号梳状支路）
reg [1:0] ap_index; // Allpass Index（0、1为左声道，2、3为右声道）
reg [12:0] comb_pointer [0:7]; // 每条梳状延迟线独立循环指针，前两条最大8192点
reg [8:0] ap_pointer [0:3]; // 每条全通延迟线独立循环指针，最大512点
reg signed [31:0] damp_state [0:7]; // 每条梳状支路独立低通历史状态
reg signed [20:0] dry_snapshot; // 当前输入样本快照，用于最终对齐干声
reg signed [31:0] input_scaled; // 当前帧混响输入，带4位小数并预衰减1/4
reg signed [31:0] delayed_sample; // RAM返回的当前历史状态
reg signed [31:0] lowpass_new; // 当前支路更新后的低通状态
reg signed [35:0] sum_left; // 左边偶数支路求和，额外保护位
reg signed [35:0] sum_right; // 右边奇数支路求和，额外保护位
reg signed [31:0] ap_input; // 当前全通滤波器输入
reg signed [31:0] ap_write_latched; // Allpass Write Register（全通写回流水寄存器），下一拍用于BRAM写入和全通输出计算
reg signed [31:0] left_work; // 左湿声内部结果，输出前保留小数
reg signed [31:0] right_work; // 右湿声内部结果，输出前保留小数
integer reset_index; // 只用于少量指针和状态寄存器复位，不用于BRAM数组复位


//滤波器延时线对应的Bram的起始地址
function [13:0] comb_base;
 input [1:0] mode;input [2:0] index;
 begin case ({mode,index})
            5'd0: comb_base = 14'd0;
            5'd1: comb_base = 14'd5761;
            5'd2: comb_base = 14'd13250;
            5'd3: comb_base = 14'd13250;
            5'd4: comb_base = 14'd13250;
            5'd5: comb_base = 14'd13250;
            5'd6: comb_base = 14'd13250;
            5'd7: comb_base = 14'd13250;
            5'd8: comb_base = 14'd0;
            5'd9: comb_base = 14'd1423;
            5'd10: comb_base = 14'd2916;
            5'd11: comb_base = 14'd4475;
            5'd12: comb_base = 14'd6058;
            5'd13: comb_base = 14'd7671;
            5'd14: comb_base = 14'd9370;
            5'd15: comb_base = 14'd11117;
            5'd16: comb_base = 14'd0;
            5'd17: comb_base = 14'd431;
            5'd18: comb_base = 14'd910;
            5'd19: comb_base = 14'd1457;
            5'd20: comb_base = 14'd2050;
            5'd21: comb_base = 14'd2691;
            5'd22: comb_base = 14'd3382;
            5'd23: comb_base = 14'd4121;
            5'd24: comb_base = 14'd0;
            5'd25: comb_base = 14'd1153;
            5'd26: comb_base = 14'd2370;
            5'd27: comb_base = 14'd3671;
            5'd28: comb_base = 14'd5032;
            5'd29: comb_base = 14'd6485;
            5'd30: comb_base = 14'd8008;
            5'd31: comb_base = 14'd9621;
 default: comb_base=0;
 endcase end
endfunction

function [13:0] ap_base;
 input [1:0] mode;input [1:0] index;
 begin case ({mode,index})
            4'd0: ap_base = 14'd13250;
            4'd1: ap_base = 14'd13250;
            4'd2: ap_base = 14'd13250;
            4'd3: ap_base = 14'd13250;
            4'd4: ap_base = 14'd12906;
            4'd5: ap_base = 14'd13117;
            4'd6: ap_base = 14'd13506;
            4'd7: ap_base = 14'd13733;
            4'd8: ap_base = 14'd4918;
            4'd9: ap_base = 14'd4979;
            4'd10: ap_base = 14'd5088;
            4'd11: ap_base = 14'd5161;
            4'd12: ap_base = 14'd11320;
            4'd13: ap_base = 14'd11469;
            4'd14: ap_base = 14'd11776;
            4'd15: ap_base = 14'd11949;
 default: ap_base=0;
 endcase end
endfunction


//延时点数查找表
function [12:0] comb_length;
    input [1:0] mode; // 预设模式
    input [2:0] index; // 梳状支路编号
    begin
        case ({mode, index})
            5'd0: comb_length = 13'd5761; // 模式0、支路0的循环延迟点数
            5'd1: comb_length = 13'd7489; // 模式0、支路1的循环延迟点数
            5'd2: comb_length = 13'd503; // 模式0、支路2的循环延迟点数
            5'd3: comb_length = 13'd607; // 模式0、支路3的循环延迟点数
            5'd4: comb_length = 13'd733; // 模式0、支路4的循环延迟点数
            5'd5: comb_length = 13'd887; // 模式0、支路5的循环延迟点数
            5'd6: comb_length = 13'd1013; // 模式0、支路6的循环延迟点数
            5'd7: comb_length = 13'd1151; // 模式0、支路7的循环延迟点数
            5'd8: comb_length = 13'd1423; // 模式1、支路0的循环延迟点数
            5'd9: comb_length = 13'd1493; // 模式1、支路1的循环延迟点数
            5'd10: comb_length = 13'd1559; // 模式1、支路2的循环延迟点数
            5'd11: comb_length = 13'd1583; // 模式1、支路3的循环延迟点数
            5'd12: comb_length = 13'd1613; // 模式1、支路4的循环延迟点数
            5'd13: comb_length = 13'd1699; // 模式1、支路5的循环延迟点数
            5'd14: comb_length = 13'd1747; // 模式1、支路6的循环延迟点数
            5'd15: comb_length = 13'd1789; // 模式1、支路7的循环延迟点数
            5'd16: comb_length = 13'd431; // 模式2、支路0的循环延迟点数
            5'd17: comb_length = 13'd479; // 模式2、支路1的循环延迟点数
            5'd18: comb_length = 13'd547; // 模式2、支路2的循环延迟点数
            5'd19: comb_length = 13'd593; // 模式2、支路3的循环延迟点数
            5'd20: comb_length = 13'd641; // 模式2、支路4的循环延迟点数
            5'd21: comb_length = 13'd691; // 模式2、支路5的循环延迟点数
            5'd22: comb_length = 13'd739; // 模式2、支路6的循环延迟点数
            5'd23: comb_length = 13'd797; // 模式2、支路7的循环延迟点数
            5'd24: comb_length = 13'd1153; // 模式3、支路0的循环延迟点数
            5'd25: comb_length = 13'd1217; // 模式3、支路1的循环延迟点数
            5'd26: comb_length = 13'd1301; // 模式3、支路2的循环延迟点数
            5'd27: comb_length = 13'd1361; // 模式3、支路3的循环延迟点数
            5'd28: comb_length = 13'd1453; // 模式3、支路4的循环延迟点数
            5'd29: comb_length = 13'd1523; // 模式3、支路5的循环延迟点数
            5'd30: comb_length = 13'd1613; // 模式3、支路6的循环延迟点数
            5'd31: comb_length = 13'd1699; // 模式3、支路7的循环延迟点数
            default: comb_length = 13'd431; // 安全默认值，处于最小分区容量内
        endcase
    end
endfunction


//滤波器反馈相关系数
function [17:0] comb_feedback;
    input [1:0] mode; // 模式对应名义RT60：山谷2.2s、大厅2.4s、房间0.45s、音乐厅1.8s
    input [2:0] index; // 系数离线按round(2^18 * 10^(-3*D/(48000*RT60)))计算
    begin
        case ({mode, index})
            5'd0: comb_feedback = 18'd179835; // 模式0、支路0的无符号Q0.18反馈增益
            5'd1: comb_feedback = 18'd160614; // 模式0、支路1的无符号Q0.18反馈增益
            5'd2: comb_feedback = 18'd0; // 模式0、支路2的无符号Q0.18反馈增益
            5'd3: comb_feedback = 18'd0; // 模式0、支路3的无符号Q0.18反馈增益
            5'd4: comb_feedback = 18'd0; // 模式0、支路4的无符号Q0.18反馈增益
            5'd5: comb_feedback = 18'd0; // 模式0、支路5的无符号Q0.18反馈增益
            5'd6: comb_feedback = 18'd0; // 模式0、支路6的无符号Q0.18反馈增益
            5'd7: comb_feedback = 18'd0; // 模式0、支路7的无符号Q0.18反馈增益
            5'd8: comb_feedback = 18'd240704; // 模式1、支路0的无符号Q0.18反馈增益
            5'd9: comb_feedback = 18'd239695; // 模式1、支路1的无符号Q0.18反馈增益
            5'd10: comb_feedback = 18'd238749; // 模式1、支路2的无符号Q0.18反馈增益
            5'd11: comb_feedback = 18'd238405; // 模式1、支路3的无符号Q0.18反馈增益
            5'd12: comb_feedback = 18'd237977; // 模式1、支路4的无符号Q0.18反馈增益
            5'd13: comb_feedback = 18'd236753; // 模式1、支路5的无符号Q0.18反馈增益
            5'd14: comb_feedback = 18'd236072; // 模式1、支路6的无符号Q0.18反馈增益
            5'd15: comb_feedback = 18'd235479; // 模式1、支路7的无符号Q0.18反馈增益
            5'd16: comb_feedback = 18'd228391; // 模式2、支路0的无符号Q0.18反馈增益
            5'd17: comb_feedback = 18'd224912; // 模式2、支路1的无符号Q0.18反馈增益
            5'd18: comb_feedback = 18'd220073; // 模式2、支路2的无符号Q0.18反馈增益
            5'd19: comb_feedback = 18'd216860; // 模式2、支路3的无符号Q0.18反馈增益
            5'd20: comb_feedback = 18'd213556; // 模式2、支路4的无符号Q0.18反馈增益
            5'd21: comb_feedback = 18'd210169; // 模式2、支路5的无符号Q0.18反馈增益
            5'd22: comb_feedback = 18'd206967; // 模式2、支路6的无符号Q0.18反馈增益
            5'd23: comb_feedback = 18'd203163; // 模式2、支路7的无符号Q0.18反馈增益
            5'd24: comb_feedback = 18'd239059; // 模式3、支路0的无符号Q0.18反馈增益
            5'd25: comb_feedback = 18'd237839; // 模式3、支路1的无符号Q0.18反馈增益
            5'd26: comb_feedback = 18'd236247; // 模式3、支路2的无符号Q0.18反馈增益
            5'd27: comb_feedback = 18'd235116; // 模式3、支路3的无符号Q0.18反馈增益
            5'd28: comb_feedback = 18'd233393; // 模式3、支路4的无符号Q0.18反馈增益
            5'd29: comb_feedback = 18'd232091; // 模式3、支路5的无符号Q0.18反馈增益
            5'd30: comb_feedback = 18'd230427; // 模式3、支路6的无符号Q0.18反馈增益
            5'd31: comb_feedback = 18'd228848; // 模式3、支路7的无符号Q0.18反馈增益
            default: comb_feedback = 18'd0; // 异常索引关闭反馈
        endcase
    end
endfunction


//低通滤波器对高频的衰减。
function [17:0] damping_alpha;
    input [1:0] mode; // 公共低通系数，数值越小，高频阻尼通常越强
    begin
        case (mode)
            2'd0: damping_alpha = 18'd196608; // 山谷0.75，保留比较清晰的重复回声
            2'd1: damping_alpha = 18'd65536; // 大厅0.25，尾音高频逐次减弱
            2'd2: damping_alpha = 18'd47186; // 房间约0.18
            default: damping_alpha = 18'd104858; // 音乐厅约0.40
        endcase
    end
endfunction


//全通滤波器对不同频段的延时进行差分。
function [8:0] allpass_length;
    input [1:0] mode; // 山谷直接旁路全通，其表值仅作安全占位
    input [1:0] index; // 全通编号，左右各两节
    begin
        case ({mode, index})
            4'd4: allpass_length = 9'd211; // 大厅左第1节
            4'd5: allpass_length = 9'd389; // 大厅左第2节
            4'd6: allpass_length = 9'd227; // 大厅右第1节
            4'd7: allpass_length = 9'd421; // 大厅右第2节
            4'd8: allpass_length = 9'd61; // 房间左第1节
            4'd9: allpass_length = 9'd109; // 房间左第2节
            4'd10: allpass_length = 9'd73; // 房间右第1节
            4'd11: allpass_length = 9'd127; // 房间右第2节
            4'd12: allpass_length = 9'd149; // 音乐厅左第1节
            4'd13: allpass_length = 9'd307; // 音乐厅左第2节
            4'd14: allpass_length = 9'd173; // 音乐厅右第1节
            4'd15: allpass_length = 9'd331; // 音乐厅右第2节
            default: allpass_length = 9'd31; // 山谷模式不会访问全通
        endcase
    end
endfunction


//取整函数，并整理为64位
function signed [63:0] round_coefficient_product;
    input signed [51:0] product; // 33位有符号状态差值与19位正系数相乘的完整结果
    reg signed [33:0] integer_part; // 算术右移18位后的向负无穷取整结果
    reg increment; // 根据被丢弃部分判定是否加1，负数恰好半LSB时不加1
    begin
        integer_part = $signed(product[51:18]); // 位选后显式恢复符号，不产生绝对值和两次宽位取负
        increment = product[17] && ((!product[51]) || (|product[16:0])); // 最近整数舍入，正负恰好半LSB均远离零
        round_coefficient_product = $signed({{30{integer_part[33]}}, integer_part}) + (increment ? 64'sd1 : 64'sd0); // 只需一次加1，结果与原对称四舍五入一致
    end
endfunction


//截位函数
function signed [31:0] saturate_state;
    input signed [63:0] value; // 已扩位的内部运算值
    begin
        if (value > 64'sd2147483647) saturate_state = 32'sh7fffffff; // 正溢出饱和
        else if (value < -64'sd2147483648) saturate_state = 32'sh80000000; // 负溢出饱和
        else saturate_state = value[31:0]; // 已确认范围合法后取低32位
    end
endfunction

//饱和检测（返回一为饱和）
function state_clipped;
    input signed [63:0] value; // 对应saturate_state的范围检测
    begin
        state_clipped = (value > 64'sd2147483647) || (value < -64'sd2147483648); // 饱和诊断，不把截断当作正常输出
    end
endfunction


//依旧数据位数对齐
function signed [63:0] audio_rounded;
    input signed [31:0] value; // 去掉4位状态小数前的音频值
    reg signed [27:0] integer_part; // 去掉4位小数后的向负无穷取整结果
    reg increment; // 对称舍入的加1条件
    begin
        integer_part = $signed(value[31:4]); // 本设计STATE_FRAC固定为4，位选直接去掉内部小数
        increment = value[3] && ((!value[31]) || (|value[2:0])); // 正负半LSB均远离零，与乘积舍入遵循同一规则
        audio_rounded = $signed({{36{integer_part[27]}}, integer_part}) + (increment ? 64'sd1 : 64'sd0); // 避免绝对值和两次宽位取负形成进位链
    end
endfunction


//最后21为输出的截位
function signed [20:0] saturate_audio;
    input signed [63:0] value; // 已恢复外部音频刻度
    begin
        if (value > 64'sd1048575) saturate_audio = 21'sh0fffff; // 21位最大正数
        else if (value < -64'sd1048576) saturate_audio = 21'sh100000; // 21位最小负数
        else saturate_audio = value[20:0]; // 合法范围内保持补码
    end
endfunction

wire comb_enabled; // 山谷只有0、1支路参与，其他模式全部参与
wire [13:0] comb_address; // 梳状分区地址
wire [13:0] ap_address; // 全通分区地址，28672～30719，剩余地址保留
wire signed [32:0] lowpass_difference; // 相减先扩位，避免32位差值溢出
reg signed [32:0] multiplier_a; // 共享乘法器第一个有符号操作数
reg signed [18:0] multiplier_b; // 正系数补零扩位后作为有符号操作数
wire multiplier_enable; // 仅低通和反馈乘法状态执行乘法
reg signed [51:0] multiplier_product; // 唯一通用乘法表达式的寄存输出
reg signed [63:0] product_scaled; // 系数小数恢复后的乘积寄存器，下一拍才做低通或反馈加法
wire signed [63:0] lowpass_wide; // 扩位的低通加法结果
wire signed [63:0] feedback_wide; // 扩位的反馈写回结果
wire signed [63:0] allpass_write_wide; // 全通写回值，输入加0.5倍旧状态
wire signed [31:0] allpass_write_state; // 饱和后的实际全通写回状态
wire signed [63:0] allpass_output_wide; // 全通输出必须使用实际写回状态计算
wire signed [63:0] left_mix_wide; // 左梳状支路平均值，保留符号
wire signed [63:0] right_mix_wide; // 右梳状支路平均值
wire signed [63:0] left_audio_wide; // 左输出舍入后的音频码值
wire signed [63:0] right_audio_wide; // 右输出舍入后的音频码值
wire ram_read_enable; // RAM同步读使能
wire ram_write_enable; // RAM同步写使能
wire [13:0] ram_read_address; // RAM读地址
wire [13:0] ram_write_address; // RAM写地址
wire signed [31:0] ram_write_data; // RAM写入状态
wire signed [31:0] ram_read_data; // RAM读出状态

assign busy = (state != ST_IDLE); // CLEAR期间busy为1但仍接受干声，这是明确的初始化例外
assign comb_enabled = (active_mode != 2'd0) || (comb_index < 3'd2); // 山谷保留左右各一条长回声
assign comb_address = comb_base(active_mode,comb_index) + {1'b0, comb_pointer[comb_index]}; // 当前梳状循环地址
assign ap_address = ap_base(active_mode,ap_index) + {5'd0, ap_pointer[ap_index]}; // 每条全通分配512点
assign lowpass_difference = $signed({delayed_sample[31], delayed_sample}) - $signed({damp_state[comb_index][31], damp_state[comb_index]}); // 两个状态先扩位再相减
assign multiplier_enable = (state == ST_LP_MULTIPLY) || (state == ST_FB_MULTIPLY); // 每支路两次乘法
assign lowpass_wide = $signed({{32{damp_state[comb_index][31]}}, damp_state[comb_index]}) + product_scaled; // 低通旧状态加更新量
assign feedback_wide = (comb_enabled ? $signed({{32{input_scaled[31]}}, input_scaled}) : 64'sd0) + product_scaled; // 当前输入只送到启用支路
assign allpass_write_wide = $signed({{32{ap_input[31]}}, ap_input}) + ($signed({{32{delayed_sample[31]}}, delayed_sample}) >>> 1); // 固定0.5全通反馈以移位实现
assign allpass_write_state = saturate_state(allpass_write_wide); // 防止全通状态回绕
assign allpass_output_wide = $signed({{32{delayed_sample[31]}}, delayed_sample}) - ($signed({{32{ap_write_latched[31]}}, ap_write_latched}) >>> 1); // 使用上一拍已寄存的写回状态，避免两次宽位加减串联
assign left_mix_wide = (active_mode == 2'd0) ? $signed({{28{sum_left[35]}}, sum_left}) : ($signed({{28{sum_left[35]}}, sum_left}) >>> 2); // 山谷一路，其余模式四路平均
assign right_mix_wide = (active_mode == 2'd0) ? $signed({{28{sum_right[35]}}, sum_right}) : ($signed({{28{sum_right[35]}}, sum_right}) >>> 2); // 左右使用相同缩放
assign left_audio_wide = audio_rounded(left_work); // 最终统一去掉4位小数
assign right_audio_wide = audio_rounded(right_work); // 最终统一去掉4位小数

always @(posedge clk) begin
    if (state == ST_LP_PREPARE) begin
        multiplier_a <= lowpass_difference; // 本拍只完成状态选择及减法，下一拍才送入乘法运算
        multiplier_b <= $signed({1'b0, damping_alpha(active_mode)}); // 无符号系数补零后寄存，避免系数选择逻辑串联乘法器
    end else if (state == ST_FB_PREPARE) begin
        multiplier_a <= $signed({lowpass_new[31], lowpass_new}); // 反馈乘法同样先寄存操作数
        multiplier_b <= $signed({1'b0, comb_feedback(active_mode, comb_index)}); // 禁止将18位系数最高位误判为符号位
    end
end

always @(posedge clk) begin
    if (multiplier_enable) multiplier_product <= multiplier_a * multiplier_b; // 只保留这一处通用乘法，物理DSP数量由位宽和综合映射决定
    if ((state == ST_LP_ROUND) || (state == ST_FB_ROUND)) product_scaled <= round_coefficient_product(multiplier_product); // 舍入结果独立寄存，禁止与反馈加法及RAM写入串在同一拍
end

assign ram_read_enable = rst_n && (((state == ST_COMB_READ) && comb_enabled) || (state == ST_AP_READ)); // 读使能只在请求状态有效
assign ram_read_address = (state == ST_AP_READ) ? ap_address : comb_address; // 共用读端口地址选择
assign ram_write_enable = rst_n && ((state == ST_CLEAR) || ((state == ST_COMB_WRITE) && comb_enabled) || (state == ST_AP_WRITE)); // 初始化和滤波共用唯一写端口
assign ram_write_address = (state == ST_CLEAR) ? clear_address[13:0] : ((state == ST_AP_WRITE) ? ap_address : comb_address); // 写回前保持原指针
assign ram_write_data = (state == ST_CLEAR) ? 32'sd0 : ((state == ST_AP_WRITE) ? ap_write_latched : saturate_state(feedback_wide)); // 全通写回值已提前一拍完成饱和与寄存


//bram手写ip
reverb_delay_bram #(
    .DATA_BITS(32), // 32位状态，含4位小数
    .ADDR_BITS(14) // 32768点共享RAM，共1048576bit
) u_delay_ram (
    .clk(clk), // 同一主时钟域
    .write_enable(ram_write_enable), // 单写端口
    .write_address(ram_write_address), // 写地址
    .write_data(ram_write_data), // 写状态
    .read_enable(ram_read_enable), // 单读端口
    .read_address(ram_read_address), // 读地址
    .read_data(ram_read_data) // 同步读结果
);



always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        mode_meta <= 2'd2; // 上电默认房间模式，随后接受外部稳定选择
        mode_sync <= 2'd2; // 同步寄存器复位
        mode_candidate <= 2'd2; // 默认候选模式
        requested_mode <= 2'd2; // 默认请求模式
        mode_stable_count <= {MODE_COUNT_BITS{1'b0}}; // 清空稳定计数
    end else begin
        mode_meta <= mode_sel; // 两级同步降低亚稳态传播风险
        mode_sync <= mode_meta; // 外部仍需保证两位模式最终稳定，机械开关需额外去抖
        if (mode_sync != mode_candidate) begin
            mode_candidate <= mode_sync; // 观察到变化，重新开始稳定判定
            mode_stable_count <= {MODE_COUNT_BITS{1'b0}}; // 丢弃上一候选模式计数
        end else if (mode_stable_count == MODE_STABLE_CYCLES - 1) begin
            requested_mode <= mode_candidate; // 稳定后提交请求，不在滤波帧中直接切换表
        end else begin
            mode_stable_count <= mode_stable_count + 1'b1; // 按主时钟计数，不要求外部对齐sample_ce
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= ST_CLEAR; // 复位释放后开始普通端口顺序清零
        active_mode <= 2'd2; // 默认房间模式
        clear_address <= 15'd0; // 从第0个存储位置清零
        comb_index <= 3'd0; // 清空运算索引
        ap_index <= 2'd0; // 清空全通索引
        dry_snapshot <= 21'sd0; // 清空当前帧输入
        input_scaled <= 32'sd0; // 清空混响发送值
        delayed_sample <= 32'sd0; // 不使用初始化前的RAM输出
        lowpass_new <= 32'sd0; // 清空乘法后状态
        sum_left <= 36'sd0; // 清空左求和
        sum_right <= 36'sd0; // 清空右求和
        ap_input <= 32'sd0; // 清空扩散器输入
        ap_write_latched <= 32'sd0; // 清空全通写回流水寄存器
        left_work <= 32'sd0; // 清空左湿声工作寄存器
        right_work <= 32'sd0; // 清空右湿声工作寄存器
        wet_left <= 21'sd0; // 复位输出静音
        wet_right <= 21'sd0; // 复位输出静音
        dry_aligned <= 21'sd0; // 复位干声输出
        out_valid <= 1'b0; // 复位期间没有有效输出
        init_done <= 1'b0; // 尚未清空BRAM
        frame_overrun <= 1'b0; // 清空粘滞时序异常
        clip_detected <= 1'b0; // 清空粘滞饱和异常
        for (reset_index = 0; reset_index < 8; reset_index = reset_index + 1) begin
            comb_pointer[reset_index] <= 13'd0; // 仅复位8个指针，不复位大数组
            damp_state[reset_index] <= 32'sd0; // 仅复位8个低通状态
        end
        for (reset_index = 0; reset_index < 4; reset_index = reset_index + 1) ap_pointer[reset_index] <= 9'd0; // 复位4个全通指针
    end else begin
        out_valid <= 1'b0; // 所有有效输出脉冲默认只持续一个clk
        if (sample_ce && (state != ST_IDLE) && (state != ST_CLEAR)) frame_overrun <= 1'b1; // 过快输入丢弃新样本，不污染正在处理的帧
        case (state)
            ST_CLEAR: begin
                active_mode <= requested_mode; // 清零期间无湿声处理，可以合并最新稳定模式，避免为中间模式重复清零
                if (sample_ce) begin
                    dry_aligned <= in_sample; // 湿声清零期间干声不停止
                    wet_left <= 21'sd0; // 清零期间输出零湿声
                    wet_right <= 21'sd0; // 左右同时静音
                    out_valid <= 1'b1; // 对每个输入仍发布一帧干声及零湿声
                end
                if (clear_address == 15'd32767) begin
                    init_done <= 1'b1; // 本上升沿已通过RAM写端口完成最后一次清零
                    clear_address <= 15'd0; // 为以后模式切换准备
                    state <= ST_IDLE; // 下一拍开始允许正常湿声输入
                end else clear_address <= clear_address + 1'b1; // 每个主时钟只写一个零
            end
            ST_IDLE: begin
                if (requested_mode != active_mode) begin
                    active_mode <= requested_mode; // 模式只在帧间切换
                    init_done <= 1'b0; // 新模式先清空所有历史反射
                    clear_address <= 15'd0; // 准备从头清空
                    state <= ST_CLEAR; // 湿声允许短暂中断，不运行两套混响
                    for (reset_index = 0; reset_index < 8; reset_index = reset_index + 1) begin
                        comb_pointer[reset_index] <= 13'd0; // 不让新延迟长度继承旧指针
                        damp_state[reset_index] <= 32'sd0; // 清空旧低通尾音
                    end
                    for (reset_index = 0; reset_index < 4; reset_index = reset_index + 1) ap_pointer[reset_index] <= 9'd0; // 清空扩散器指针
                    if (sample_ce) begin
                        dry_aligned <= in_sample; // 切换触发边沿若恰好有输入，也不丢失干声
                        wet_left <= 21'sd0; // 该帧从零湿声过渡
                        wet_right <= 21'sd0; // 允许直接截断旧尾音，未实现淡入淡出
                        out_valid <= 1'b1; // 干声继续发布
                    end
                end else if (sample_ce) begin
                    dry_snapshot <= in_sample; // 锁存当前帧原始21位样本
                    input_scaled <= ($signed({{11{in_sample[20]}}, in_sample}) <<< STATE_FRAC) >>> INPUT_SHIFT; // 保留4位内部小数，并预衰减1/4
                    sum_left <= 36'sd0; // 开始新的梳状求和
                    sum_right <= 36'sd0; // 左右独立求和
                    comb_index <= 3'd0; // 从第0条支路开始
                    state <= ST_COMB_READ; // 下一拍发起第一个RAM读
                end
            end
            ST_COMB_READ: state <= ST_COMB_CAPTURE; // RAM在本边沿采样地址，不能同拍消费刚更新的读数据
            ST_COMB_CAPTURE: begin
                delayed_sample <= comb_enabled ? ram_read_data : 32'sd0; // 本拍取走上一拍同步读结果
                state <= ST_LP_PREPARE; // 先准备低通乘法操作数
            end
            ST_LP_PREPARE: state <= ST_LP_MULTIPLY; // 本拍寄存差值及系数，下一拍执行乘法
            ST_LP_MULTIPLY: state <= ST_LP_ROUND; // 本拍共享乘法器锁存差值乘alpha
            ST_LP_ROUND: state <= ST_LP_UPDATE; // 本拍独立舍入乘积，下一拍更新低通
            ST_LP_UPDATE: begin
                lowpass_new <= saturate_state(lowpass_wide); // 取上一拍乘积，得到新低通状态
                damp_state[comb_index] <= saturate_state(lowpass_wide); // 每个支路状态只更新一次
                if (state_clipped(lowpass_wide)) clip_detected <= 1'b1; // 低通异常幅度诊断
                state <= ST_FB_PREPARE; // 新低通值先经过乘法器输入寄存器
            end
            ST_FB_PREPARE: state <= ST_FB_MULTIPLY; // 本拍寄存反馈操作数，下一拍执行乘法
            ST_FB_MULTIPLY: state <= ST_FB_ROUND; // 本拍乘法器锁存低通输出乘反馈系数
            ST_FB_ROUND: state <= ST_COMB_WRITE; // 本拍独立舍入反馈乘积，下一拍再执行加法和写回
            ST_COMB_WRITE: begin
                if (state_clipped(feedback_wide)) clip_detected <= 1'b1; // RAM同拍写入饱和后的反馈值
                if (comb_enabled) begin
                    if (!comb_index[0]) sum_left <= sum_left + $signed({{4{delayed_sample[31]}}, delayed_sample}); // 偶数支路送左边
                    else sum_right <= sum_right + $signed({{4{delayed_sample[31]}}, delayed_sample}); // 奇数支路送右边
                end
                if (comb_pointer[comb_index] == comb_length(active_mode, comb_index) - 1'b1) comb_pointer[comb_index] <= 13'd0; // 到延迟长度后循环
                else comb_pointer[comb_index] <= comb_pointer[comb_index] + 1'b1; // 一个音频样本只推进一次指针
                if (comb_index == 3'd7) state <= ST_MIX; // 已处理全部8条支路
                else begin
                    comb_index <= comb_index + 1'b1; // 共用乘法器切换下一个支路
                    state <= ST_COMB_READ; // 重新发起下一支路的同步读
                end
            end
            //==============================================================到此为止处理完所有梳妆滤波器计算==========================================================================
            //滤波器结果求和
            ST_MIX: begin
                if (state_clipped(left_mix_wide) || state_clipped(right_mix_wide)) clip_detected <= 1'b1; // 求和缩放后的范围检查
                if (active_mode == 2'd0) begin
                    left_work <= saturate_state(left_mix_wide); // 山谷保留离散回声，不做全通扩散
                    right_work <= saturate_state(right_mix_wide); // 左右回声间隔不同
                    state <= ST_OUTPUT; // 直接发布山谷湿声
                end else begin
                    ap_input <= saturate_state(left_mix_wide); // 先计算左声道全通链
                    ap_index <= 2'd0; // 左第1个全通
                    state <= ST_AP_READ; // 开始全通读写序列
                end
            end
            ST_AP_READ: state <= ST_AP_CAPTURE; // 等待同步RAM读结果
            ST_AP_CAPTURE: begin
                delayed_sample <= ram_read_data; // 保存当前全通历史状态
                state <= ST_AP_PREPARE; // 先计算并寄存写回状态，不把两次加减放在同一拍
            end
            ST_AP_PREPARE: begin
                ap_write_latched <= allpass_write_state; // 先保存已饱和的全通写回值
                if (state_clipped(allpass_write_wide)) clip_detected <= 1'b1; // 写回值范围检查与输出值检查分拍完成
                state <= ST_AP_WRITE; // 下一拍独立计算输出并写入RAM
            end
            ST_AP_WRITE: begin
                if (state_clipped(allpass_output_wide)) clip_detected <= 1'b1; // 此拍只检查全通输出，写回值已在上一拍检查
                if (ap_pointer[ap_index] == allpass_length(active_mode, ap_index) - 1'b1) ap_pointer[ap_index] <= 9'd0; // 全通按自身长度循环
                else ap_pointer[ap_index] <= ap_pointer[ap_index] + 1'b1; // 全通指针每帧更新一次
                if (ap_index == 2'd1) begin
                    left_work <= saturate_state(allpass_output_wide); // 左两节完成，保存左湿声
                    ap_input <= saturate_state(right_mix_wide); // 准备右边的梳状求和结果
                end else ap_input <= saturate_state(allpass_output_wide); // 同一声道两节全通串联
                if (ap_index == 2'd3) begin
                    right_work <= saturate_state(allpass_output_wide); // 右两节也完成
                    state <= ST_OUTPUT; // 下一拍同时发布左右结果
                end else begin
                    ap_index <= ap_index + 1'b1; // 下一节全通继续复用同一RAM和加减逻辑
                    state <= ST_AP_READ; // 发起下一个全通读
                end
            end
            ST_OUTPUT: begin
                wet_left <= saturate_audio(left_audio_wide); // 舍入后缩成21位外部格式
                wet_right <= saturate_audio(right_audio_wide); // 左右保持相同刻度
                dry_aligned <= dry_snapshot; // 干声与本次湿声处理对应，不经过延迟线
                out_valid <= 1'b1; // 一次输入只发布一帧输出
                if ((left_audio_wide > 64'sd1048575) || (left_audio_wide < -64'sd1048576) || (right_audio_wide > 64'sd1048575) || (right_audio_wide < -64'sd1048576)) clip_detected <= 1'b1; // 输出峰值保护诊断
                state <= ST_IDLE; // 输出发布后的下一拍可接收新样本
            end
            default: begin
                state <= ST_CLEAR; // 非法状态清空历史，等待外部复位诊断标志
                clear_address <= 15'd0; // 恢复存储初始化
                init_done <= 1'b0; // 禁止使用未知湿声
                frame_overrun <= 1'b1; // 报告异常状态
                for (reset_index = 0; reset_index < 8; reset_index = reset_index + 1) begin
                    comb_pointer[reset_index] <= 13'd0; // 恢复指针
                    damp_state[reset_index] <= 32'sd0; // 恢复低通状态
                end
                for (reset_index = 0; reset_index < 4; reset_index = reset_index + 1) ap_pointer[reset_index] <= 9'd0; // 恢复全通指针
            end
        endcase
    end
end

endmodule
