module eq_preset_bank #(
    parameter COEFF_FILE = "eq_coeff_48k.mem", // 固定系数ROM；采样率必须为48kHz
    parameter integer SILENCE_FRAMES = 48000 // 连续精确零输入达到1秒后清状态，避免无输入极限环残留
)(
    input wire clk, // 主时钟，目标49.152MHz，不是48kHz方波
    input wire rst_n, // 异步低电平控制复位；历史RAM通过8拍扫描清零
    input wire in_valid, // 加法器输出有效脉冲，只在in_ready为1时提交
    input wire signed [20:0] in_sample, // 加法器21位有符号结果，不预先缩位
    input wire [2:0] mode_select, // 固定模式编号0到5；6、7按直通处理；必须同步到clk
    output wire in_ready, // 空闲并已完成初始化时为1
    output reg out_valid, // 滤波后样本有效脉冲，连接AGC输入有效端
    output reg signed [20:0] out_sample, // 21位补码结果，末端饱和，保持原输入幅度标度
    output wire busy, // 初始化、运算和状态清除期间为1
    output reg overrun, // 忙时收到in_valid置1，粘滞到复位；该输入被丢弃
    output reg clipped, // 内部或输出饱和时置1，粘滞到复位，用于检测余量不足
    output reg [9:0] cycles_used, // 最近一帧从接收到输出消耗的主时钟数
    output reg [2:0] active_mode // 当前正在计算的预设编号，切换经过短暂淡出淡入
);

localparam [3:0] IDLE=0, CLEAR=1, PREP=2, ROM_WAIT=3, OPERANDS=4, MULTIPLY=5, ACCUMULATE=6, ROUND=7, COMMIT=8, GAIN_LOAD=9, GAIN_MULTIPLY=10, GAIN_ROUND=11, OUTPUT_SAMPLE=12;
reg [3:0] state; // 串行处理状态机，同一乘法器依次计算所有二阶节
reg [2:0] stage_index; // 二阶节编号0到7，每节拥有独立历史状态
reg [2:0] term_index; // 乘积编号0到4：b0*x、b1*x1、b2*x2、-a1*y1、-a2*y2
reg [2:0] clear_index; // 清除历史状态时使用的地址
reg resume_frame; // 为1表示清除后继续已锁存的采样，为0表示初始化后进入空闲
reg [9:0] cycle_count; // 当前帧运行周期计数，正常运行远小于1024
reg [15:0] zero_count; // 连续精确零输入样本数，非噪声门，不检测小信号幅度
reg [6:0] fade_gain; // 模式切换线性淡变刻度0到64，64代表单位增益
reg [6:0] frame_gain; // 本帧锁存的淡变增益，运算过程中不改变
wire [2:0] requested_mode = (mode_select < 3'd6) ? mode_select : 3'd0; // 保留编号安全映射为直通
wire change_now = (requested_mode != active_mode) && (fade_gain == 0); // 只有已经淡出到零才换系数并清历史
wire silence_clear = (in_sample == 0) && (zero_count >= SILENCE_FRAMES-1); // 仅无输入足够久后清除残留

// 四个小型状态阵列各8个24位字；不做异步RAM复位，允许综合成分布式RAM。
(* ram_style="distributed" *) reg signed [23:0] x1_mem [0:7]; // 每节上一个输入
(* ram_style="distributed" *) reg signed [23:0] x2_mem [0:7]; // 每节上上个输入
(* ram_style="distributed" *) reg signed [23:0] y1_mem [0:7]; // 每节上一个输出
(* ram_style="distributed" *) reg signed [23:0] y2_mem [0:7]; // 每节上上个输出
(* ram_style="block" *) reg signed [23:0] coefficient_mem [0:511]; // 512×24位同步只读ROM
reg signed [23:0] coefficient_q; // ROM同步读取后的系数，24位补码，21位小数
wire [8:0] coefficient_address = {active_mode, stage_index, term_index}; // 每模式64字，每节8字，前5字有效
initial $readmemh(COEFF_FILE, coefficient_mem); // 初始化的是滤波系数，不是预录音频
always @(posedge clk) coefficient_q <= coefficient_mem[coefficient_address]; // 一拍同步ROM读取

reg signed [23:0] work_sample; // 当前二阶节输入，比21位接口多3位幅度保护位
reg signed [23:0] stage_result; // 舍入并饱和后的当前节输出
reg signed [23:0] mul_a; // 所有二阶节和切换淡变共同使用的乘法输入A
reg signed [23:0] mul_b; // 共同使用的乘法输入B，固定点系数
(* use_dsp="yes" *) reg signed [47:0] product; // 完整24×24位乘积；整个模块只有这一处乘法
reg signed [51:0] accumulator; // 五项乘积的宽位累加器，加法分拍完成
reg signed [51:0] scaled_result; // 右移21位并对称舍入后的整数结果
reg signed [51:0] output_scaled; // 淡变加权后的宽位结果，下一拍饱和到21位
wire signed [51:0] product_extended = {{4{product[47]}}, product}; // 将48位乘积符号扩展为52位

assign busy = (state != IDLE); // 忙状态直接由状态机导出
assign in_ready = (state == IDLE); // 使用一个主时钟域内的有效/就绪接口

function signed [51:0] round_q21;
    input signed [51:0] value; // 输入完整累加结果，低21位为系数产生的小数部分
    reg signed [51:0] floor_value; // 算术右移得到向负无穷取整结果
    reg increment; // 最近整数舍入，恰好半LSB时远离零
    begin
        floor_value = value >>> 21;
        increment = value[20] && ((!value[51]) || (|value[19:0]));
        round_q21 = floor_value + (increment ? 52'sd1 : 52'sd0);
    end
endfunction

function signed [23:0] saturate24;
    input signed [51:0] value; // 保护二阶节内部溢出，正常工作应保持clipped为0
    begin
        if (value > 52'sd8388607) saturate24 = 24'sh7fffff;
        else if (value < -52'sd8388608) saturate24 = 24'sh800000;
        else saturate24 = value[23:0];
    end
endfunction

// RAM写入独立于控制复位，复位后CLEAR状态逐地址清零，避免综合成带复位的大量FF。
always @(posedge clk) begin
    if (rst_n && state == CLEAR) begin
        x1_mem[clear_index] <= 24'sd0;
        x2_mem[clear_index] <= 24'sd0;
        y1_mem[clear_index] <= 24'sd0;
        y2_mem[clear_index] <= 24'sd0;
    end else if (rst_n && state == COMMIT) begin
        x2_mem[stage_index] <= x1_mem[stage_index]; // 更新本节输入历史，不与其他节共享状态
        x1_mem[stage_index] <= work_sample;
        y2_mem[stage_index] <= y1_mem[stage_index]; // 更新本节输出历史
        y1_mem[stage_index] <= stage_result;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= CLEAR;
        stage_index <= 0;
        term_index <= 0;
        clear_index <= 0;
        resume_frame <= 0;
        cycle_count <= 0;
        cycles_used <= 0;
        zero_count <= 0;
        active_mode <= 0;
        fade_gain <= 0; // 初次启动也进行64帧淡入，约1.33ms
        frame_gain <= 0;
        out_valid <= 0;
        out_sample <= 0;
        overrun <= 0;
        clipped <= 0;
        work_sample <= 0;
        stage_result <= 0;
        mul_a <= 0;
        mul_b <= 0;
        product <= 0;
        accumulator <= 0;
        scaled_result <= 0;
        output_scaled <= 0;
    end else begin
        out_valid <= 1'b0; // 结果有效仅保持一个主时钟周期
        if (in_valid && !in_ready) overrun <= 1'b1; // 不覆盖正在处理的样本
        if (state != IDLE && resume_frame) cycle_count <= cycle_count + 1'b1;
        case (state)
            IDLE: if (in_valid) begin
                work_sample <= {{3{in_sample[20]}}, in_sample}; // 仅符号扩展，不放大输入
                stage_index <= 0;
                term_index <= 0;
                cycle_count <= 0;
                resume_frame <= 1;
                if (in_sample != 0) zero_count <= 0;
                else if (zero_count < SILENCE_FRAMES) zero_count <= zero_count + 1'b1;
                if (requested_mode != active_mode) begin
                    if (fade_gain != 0) begin
                        fade_gain <= fade_gain - 1'b1;
                        frame_gain <= fade_gain - 1'b1; // 仍使用旧系数，先逐帧淡出
                    end else begin
                        active_mode <= requested_mode; // 输出增益为0时更换整套ROM索引
                        frame_gain <= 0;
                    end
                end else if (fade_gain < 7'd64) begin
                    fade_gain <= fade_gain + 1'b1;
                    frame_gain <= fade_gain + 1'b1; // 新模式逐帧淡入，整个过程不增加乘法器
                end else frame_gain <= 7'd64;
                if (change_now || silence_clear) begin
                    clear_index <= 0;
                    state <= CLEAR;
                end else state <= PREP;
            end
            CLEAR: begin
                if (clear_index == 7) begin
                    clear_index <= 0;
                    state <= resume_frame ? PREP : IDLE;
                end else clear_index <= clear_index + 1'b1;
            end
            PREP: begin
                accumulator <= 0; // 每节独立累加，不能将上节乘积残留带入下节
                term_index <= 0;
                state <= ROM_WAIT;
            end
            ROM_WAIT: state <= OPERANDS; // 等待新地址对应的ROM同步数据
            OPERANDS: begin
                case (term_index)
                    0: mul_a <= work_sample;
                    1: mul_a <= x1_mem[stage_index];
                    2: mul_a <= x2_mem[stage_index];
                    3: mul_a <= y1_mem[stage_index];
                    default: mul_a <= y2_mem[stage_index];
                endcase
                mul_b <= coefficient_q;
                state <= MULTIPLY;
            end
            MULTIPLY, GAIN_MULTIPLY: begin
                product <= mul_a * mul_b; // 唯一的宽位乘法运算，共享于全部模式、滤波节与淡变
                state <= (state == MULTIPLY) ? ACCUMULATE : GAIN_ROUND;
            end
            ACCUMULATE: begin
                accumulator <= accumulator + product_extended; // 每拍只进行一次52位加法
                if (term_index == 4) state <= ROUND;
                else begin
                    term_index <= term_index + 1'b1;
                    state <= ROM_WAIT;
                end
            end
            ROUND: begin
                scaled_result <= round_q21(accumulator); // 与乘法、累加分拍，不形成长组合链
                state <= COMMIT;
                stage_result <= saturate24(round_q21(accumulator)); // 本节结束后量化，随后才进入下一节
            end
            COMMIT: begin
                if (scaled_result > 52'sd8388607 || scaled_result < -52'sd8388608) clipped <= 1'b1;
                work_sample <= stage_result;
                if (stage_index == 7) state <= GAIN_LOAD;
                else begin
                    stage_index <= stage_index + 1'b1;
                    state <= PREP;
                end
            end
            GAIN_LOAD: begin
                mul_a <= work_sample;
                mul_b <= $signed({2'b00, frame_gain, 15'b0}); // frame_gain/64转换为21位小数的正系数
                state <= GAIN_MULTIPLY;
            end
            GAIN_ROUND: begin
                output_scaled <= round_q21(product_extended);
                state <= OUTPUT_SAMPLE;
            end
            OUTPUT_SAMPLE: begin
                if (output_scaled > 52'sd1048575) begin out_sample <= 21'sh0fffff; clipped <= 1; end
                else if (output_scaled < -52'sd1048576) begin out_sample <= 21'sh100000; clipped <= 1; end
                else out_sample <= output_scaled[20:0];
                out_valid <= 1;
                cycles_used <= cycle_count + 1'b1;
                resume_frame <= 0;
                state <= IDLE;
            end
            default: begin state <= CLEAR; clear_index <= 0; resume_frame <= 0; end
        endcase
    end
end
endmodule
