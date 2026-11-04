`timescale 1ns/1ps

module agc_mean_21 #(
    parameter [20:0] TARGET_MEAN = 21'd262143, // Target Mean（目标平均绝对电平），默认取有符号19位正满幅；不是瞬时峰值上限
    parameter integer IIR_SHIFT = 8, // IIR Shift（一阶检波系数的移位数），系数为1/256，48kHz下时间常数约5.33ms
    parameter integer PIPELINE_CONTROL = 0,
    parameter integer CONTROL_SHIFT = 5 // Control Shift（积分控制步长的移位数），误差除32后调整Q1.24增益，数值越大控制越慢
)(
    input wire clk, // System Clock（主时钟），例如98.304MHz，不能把48kHz使能脉冲接到此端口
    input wire rst_n, // Reset（异步低有效复位），复位后增益为1，输入静音不会积累超过1的增益
    input wire sample_ce, // Sample Enable（输入样本有效使能），48kHz单个clk周期脉冲，输入在接收边沿前稳定
    input wire signed [20:0] in_data, // Input Data（21位有符号混音输入），上游32路16位样本须先符号扩展再求和
    output reg signed [20:0] out_data, // Output Data（21位有符号输出），始终经过同一增益通路，不做阈值硬切换
    output reg out_valid, // Output Valid（输出有效脉冲），在接收输入之后的下一个clk上升沿发布，后级按此脉冲读取
    output reg [24:0] gain_q24, // Gain Q1.24（供后续样本使用的增益），16777216表示1，限制范围为0～1
    output reg [20:0] mean_level // Mean Level（本次输出更新后的平均绝对电平），不是RMS，也不是ADSR
);

localparam integer GAIN_FRAC = 24; // Gain Fraction（增益小数位数），保留足够积分精度以避免明显的增益台阶
localparam [24:0] GAIN_ONE = 25'd16777216; // Unity Gain（单位增益），2的24次方，对应音频原幅度通过
localparam integer IIR_BITS = 22 + IIR_SHIFT; // IIR Width（内部一阶状态位宽），包含幅度、保护位和IIR_SHIFT位小数余量

reg signed [46:0] product_reg; // Product Register（21位音频乘26位有符号正增益的完整47位乘积），只有这里包含乘法
reg product_valid; // Product Valid（乘积对应一个真实输入样本），防止在样本间隙反复更新控制状态
reg signed [IIR_BITS-1:0] detector_acc; // Detector Accumulator（一阶IIR唯一历史状态），增加的小数位保存移位滤波余量
wire signed [25:0] signed_gain; // Signed Gain（补零后的正增益），避免有符号音频和无符号增益相乘产生解释错误
wire signed [46:0] scaled_product; // Scaled Product（完整乘积算术右移24位），采用向负无穷截断，单位增益时逐位不变
wire signed [20:0] output_sample; // Output Sample（即将发布的本次输出），增益不超过1，因此可安全保留21位
wire [20:0] output_magnitude; // Output Magnitude（输出的无符号绝对值），21位可表示最小负数-1048576的幅度1048576
wire signed [IIR_BITS-1:0] magnitude_extended; // Extended Magnitude（零扩展的非负幅度），不能把绝对值按原音频符号扩展
wire signed [IIR_BITS-1:0] detector_next; // Next Detector State（本次样本更新后的一阶状态），不是第二级滤波
wire [20:0] mean_next; // Next Mean（本次更新后的整数平均绝对电平），滤波的小数余量仍保留在detector_acc中
reg signed [26:0] registered_error;reg gain_update;
wire signed [26:0] level_error; // Level Error（检测电平减目标值），正误差减小增益，负误差恢复增益
wire signed [26:0] control_step; // Control Step（带符号积分步长），量纲为Q1.24增益寄存器的最低位
wire signed [26:0] gain_candidate; // Candidate Gain（扩位的下一增益），先计算再限幅，不能等寄存器溢出后再补救

assign signed_gain = $signed({1'b0, gain_q24}); // 把Q1.24无符号非负增益扩为26位有符号数
assign scaled_product = product_reg >>> GAIN_FRAC; // 去除增益的24位小数，保留音频原始数值尺度
assign output_sample = scaled_product[20:0]; // 增益为0～1，输入又是21位，因此本次缩位不会产生音频回绕
assign output_magnitude = output_sample[20] ? (~output_sample + 21'd1) : output_sample; // 使用无符号容器保存补码绝对值，正确处理负满幅
assign magnitude_extended = $signed({{(IIR_BITS-21){1'b0}}, output_magnitude}); // 幅度按非负数扩位后送入有符号IIR加减器
assign detector_next = detector_acc - (detector_acc >>> IIR_SHIFT) + magnitude_extended; // 一阶低通递推，状态内部隐含IIR_SHIFT位小数
assign mean_next = detector_next >> IIR_SHIFT; // 取本次更新后的一阶平均幅度，不能对结果再增加一级IIR
wire signed [26:0] next_error=$signed({6'd0, mean_next})-$signed({6'd0, TARGET_MEAN});
assign level_error = PIPELINE_CONTROL ? registered_error : next_error; // 两个非负数先扩位再相减，避免无符号减法借位问题
// Signed round-to-nearest, ties away from zero; exact for all legal errors.
localparam signed [26:0] ROUND_HALF = (27'sd1 << CONTROL_SHIFT) >>> 1;
wire signed [26:0] round_bias = level_error[26] ? (ROUND_HALF - 27'sd1) : ROUND_HALF;
assign control_step = (CONTROL_SHIFT == 0) ? level_error : ((level_error + round_bias) >>> CONTROL_SHIFT);
assign gain_candidate = $signed({2'b00, gain_q24}) - control_step; // 在足够宽的临时值中计算候选增益，保留越界信息供限幅判断

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        registered_error<=0;gain_update<=0;
        product_reg <= 47'sd0; // 清空音频乘法流水
        product_valid <= 1'b0; // 复位不产生有效样本
        out_data <= 21'sd0; // 复位输出静音
        out_valid <= 1'b0; // 清空输出有效脉冲
        detector_acc <= {IIR_BITS{1'b0}}; // 清空一阶检波的历史状态
        mean_level <= 21'd0; // 初始检测电平为0
        gain_q24 <= GAIN_ONE; // 初始单位增益，小信号无需等待增益从0爬升
    end else begin
        gain_update<=product_valid;
        if(product_valid)registered_error<=next_error;
        product_valid <= sample_ce; // 使能只作为数据有效标记传入一级流水，绝不作为内部时钟
        out_valid <= product_valid; // 乘积发布时产生输出有效脉冲
        if (sample_ce) begin
            product_reg <= in_data * signed_gain; // 唯一音频乘法，冻结本次输入及实际使用的增益
        end
        if (product_valid) begin
            out_data <= output_sample; // 发布本次样本，其他主时钟周期保持输出不变
            detector_acc <= detector_next; // 每个有效音频输出只递推一次IIR，实际更新率为48kHz
            mean_level <= mean_next; // 同步发布供观察的平均绝对电平
        end
        if (PIPELINE_CONTROL ? gain_update : product_valid) begin
            if (gain_candidate > $signed({2'b00, GAIN_ONE})) begin
                gain_q24 <= GAIN_ONE; // 对积分器状态本身进行上限钳位，避免静音时发生积分饱和积累
            end else if (gain_candidate < 27'sd0) begin
                gain_q24 <= 25'd0; // 候选增益为负时直接钳到0，禁止反相和数值回绕
            end else begin
                gain_q24 <= gain_candidate[24:0]; // 合法候选写回，下一音频样本采用更新后的增益
            end
        end
    end
end

// synthesis translate_off
initial begin
    if (TARGET_MEAN == 0 || TARGET_MEAN > 21'd1048576 || IIR_SHIFT < 1 || IIR_SHIFT > 20 || CONTROL_SHIFT < 0 || CONTROL_SHIFT > 20) begin
        $display("AGC_PARAMETER_ERROR: check TARGET_MEAN, IIR_SHIFT and CONTROL_SHIFT"); // 检查固定点宽度和参数范围，不代表任意参数组合都具有足够稳定裕量
        $finish; // 非法参数终止仿真
    end
end
// synthesis translate_on

endmodule