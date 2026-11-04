
module stereo_output_mixer #(
    parameter integer AUDIO_BITS = 21, // Audio Bits（外部音频位宽），支持2～24位有符号补码
    parameter integer GAIN_BITS = 18, // Gain Bits（增益位宽），本版固定为18位无符号Q0.18
    parameter integer PAN_BITS = 5 // Pan Bits（声像位宽），本版固定5位32档
)(
    input wire clk, // System Clock（主时钟），例如98.333MHz
    input wire rst_n, // Reset（异步低有效复位），顶层应同步释放
    input wire in_valid, // Input Valid（单clk有效脉冲），连接混响out_valid
    input wire signed [AUDIO_BITS-1:0] dry_in, // Dry Input（单声道干声）
    input wire signed [AUDIO_BITS-1:0] wet_left_in, // Wet Left（左纯湿声）
    input wire signed [AUDIO_BITS-1:0] wet_right_in, // Wet Right（右纯湿声）
    input wire [PAN_BITS-1:0] dry_pan_select, // Dry Pan（声像），0最左、16正中、31最右
    input wire [GAIN_BITS-1:0] dry_gain, // Dry Gain（干声增益），0～262143对应0～接近1
    input wire [GAIN_BITS-1:0] wet_gain, // Wet Gain（左右公共湿声增益），无符号Q0.18
    input wire [GAIN_BITS-1:0] wet_width, // Wet Width（湿声宽度），0收窄为单声道，最大值接近原始宽度
    input wire [GAIN_BITS-1:0] master_gain, // Master Gain（左右公共总音量），无符号Q0.18
    output reg out_valid, // Output Valid（左右结果同时有效），单clk脉冲
    output reg signed [AUDIO_BITS-1:0] audio_left, // Audio Left（最终左声道）
    output reg signed [AUDIO_BITS-1:0] audio_right, // Audio Right（最终右声道）
    output wire busy, // Busy（本帧正在计算），输出发布后恢复空闲
    output reg frame_overrun, // Frame Overrun（忙时新输入被丢弃），粘滞指示，复位清除
    output reg clip_detected // Clip Detected（最终任一路输出饱和），粘滞指示，复位清除
);
localparam integer FRAC_BITS = 4; // Fraction Bits（内部保留4位小数）
localparam integer WORK_BITS = AUDIO_BITS + FRAC_BITS + 2; // Work Bits（内部位宽），增加两位混合保护位
localparam integer PRODUCT_BITS = WORK_BITS + GAIN_BITS + 1; // Product Bits（完整乘积位宽），系数补零后为19位正数
localparam [3:0] ST_IDLE = 0, ST_MID_SIDE = 1, ST_LOAD = 2, ST_MULTIPLY = 3, ST_ROUND = 4; // 空闲、中侧计算、操作数寄存、乘法、舍入
localparam [3:0] ST_STORE = 5, ST_WIDTH_MIX = 6, ST_MIX = 7, ST_OUTPUT_ROUND = 8, ST_OUTPUT = 9; // 结果存储、宽度重建、干湿相加、输出舍入、输出发布
reg [3:0] state; // 当前调度状态
reg [2:0] operation_index; // Operation Index（任务编号），每帧固定8次乘法
reg signed [WORK_BITS-1:0] dry_snapshot; // 干声快照，保留4位内部小数
reg signed [WORK_BITS-1:0] wet_l_snapshot; // 左湿声快照
reg signed [WORK_BITS-1:0] wet_r_snapshot; // 右湿声快照
reg [PAN_BITS-1:0] pan_snapshot; // 声像选择快照
reg [GAIN_BITS-1:0] dry_gain_snapshot; // 干声增益快照
reg [GAIN_BITS-1:0] wet_gain_snapshot; // 湿声增益快照
reg [GAIN_BITS-1:0] width_snapshot; // 宽度快照
reg [GAIN_BITS-1:0] master_snapshot; // 总音量快照
reg signed [WORK_BITS-1:0] mid_value; // Mid（左右湿声平均分量）
reg signed [WORK_BITS-1:0] side_value; // Side（左右湿声差的一半）
reg signed [WORK_BITS-1:0] dry_scaled; // 公共干声增益加权结果
reg signed [WORK_BITS-1:0] dry_left; // 左声像干声
reg signed [WORK_BITS-1:0] dry_right; // 右声像干声
reg signed [WORK_BITS-1:0] side_scaled; // 宽度加权后的侧分量
reg signed [WORK_BITS-1:0] wet_left_work; // 重建和增益加权后的左湿声
reg signed [WORK_BITS-1:0] wet_right_work; // 重建和增益加权后的右湿声
reg signed [WORK_BITS-1:0] mixed_left; // 左干湿和及总音量加权结果
reg signed [WORK_BITS-1:0] mixed_right; // 右干湿和及总音量加权结果
reg signed [WORK_BITS-1:0] output_left_rounded; // 去掉小数后保留保护位的左结果
reg signed [WORK_BITS-1:0] output_right_rounded; // 去掉小数后保留保护位的右结果
reg signed [WORK_BITS-1:0] multiplier_a; // 共享乘法器音频操作数寄存器
reg signed [GAIN_BITS:0] multiplier_b; // 共享乘法器系数寄存器，最高位补0
reg signed [PRODUCT_BITS-1:0] multiplier_product; // 共享乘法器完整乘积
reg signed [WORK_BITS-1:0] rounded_product; // 独立舍入拍的结果寄存器
wire [35:0] pan_coefficients; // 声像系数，高18位左增益、低18位右增益
wire signed [WORK_BITS-1:0] audio_max; // 外部有符号正满幅，扩展为内部位宽
wire signed [WORK_BITS-1:0] audio_min; // 外部有符号负满幅，扩展为内部位宽
assign busy = (state != ST_IDLE); // 忙时不接受新帧，包括本次输出发布边沿
assign pan_coefficients = pan_pair(pan_snapshot); // 查表只依赖锁存配置
assign audio_max = {{(WORK_BITS-AUDIO_BITS){1'b0}}, 1'b0, {(AUDIO_BITS-1){1'b1}}}; // 正满幅扩位
assign audio_min = {{(WORK_BITS-AUDIO_BITS){1'b1}}, 1'b1, {(AUDIO_BITS-1){1'b0}}}; // 负满幅符号扩展

function [35:0] pan_pair;
    input [4:0] pan; // 32档等功率声像，16精确居中，中心两侧步长略有不同
    begin
        case (pan)
            5'd0: pan_pair = {18'd262143, 18'd0}; // 声像0，高18位左增益，低18位右增益
            5'd1: pan_pair = {18'd261827, 18'd12863}; // 声像1，高18位左增益，低18位右增益
            5'd2: pan_pair = {18'd260881, 18'd25695}; // 声像2，高18位左增益，低18位右增益
            5'd3: pan_pair = {18'd259306, 18'd38464}; // 声像3，高18位左增益，低18位右增益
            5'd4: pan_pair = {18'd257106, 18'd51142}; // 声像4，高18位左增益，低18位右增益
            5'd5: pan_pair = {18'd254287, 18'd63696}; // 声像5，高18位左增益，低18位右增益
            5'd6: pan_pair = {18'd250855, 18'd76096}; // 声像6，高18位左增益，低18位右增益
            5'd7: pan_pair = {18'd246819, 18'd88313}; // 声像7，高18位左增益，低18位右增益
            5'd8: pan_pair = {18'd242189, 18'd100318}; // 声像8，高18位左增益，低18位右增益
            5'd9: pan_pair = {18'd236974, 18'd112081}; // 声像9，高18位左增益，低18位右增益
            5'd10: pan_pair = {18'd231189, 18'd123573}; // 声像10，高18位左增益，低18位右增益
            5'd11: pan_pair = {18'd224848, 18'd134768}; // 声像11，高18位左增益，低18位右增益
            5'd12: pan_pair = {18'd217964, 18'd145639}; // 声像12，高18位左增益，低18位右增益
            5'd13: pan_pair = {18'd210555, 18'd156158}; // 声像13，高18位左增益，低18位右增益
            5'd14: pan_pair = {18'd202639, 18'd166302}; // 声像14，高18位左增益，低18位右增益
            5'd15: pan_pair = {18'd194235, 18'd176044}; // 声像15，高18位左增益，低18位右增益
            5'd16: pan_pair = {18'd185363, 18'd185363}; // 声像16，高18位左增益，低18位右增益
            5'd17: pan_pair = {18'd175408, 18'd194810}; // 声像17，高18位左增益，低18位右增益
            5'd18: pan_pair = {18'd164972, 18'd203723}; // 声像18，高18位左增益，低18位右增益
            5'd19: pan_pair = {18'd154084, 18'd212078}; // 声像19，高18位左增益，低18位右增益
            5'd20: pan_pair = {18'd142773, 18'd219852}; // 声像20，高18位左增益，低18位右增益
            5'd21: pan_pair = {18'd131072, 18'd227022}; // 声像21，高18位左增益，低18位右增益
            5'd22: pan_pair = {18'd119010, 18'd233571}; // 声像22，高18位左增益，低18位右增益
            5'd23: pan_pair = {18'd106623, 18'd239480}; // 声像23，高18位左增益，低18位右增益
            5'd24: pan_pair = {18'd93944, 18'd244732}; // 声像24，高18位左增益，低18位右增益
            5'd25: pan_pair = {18'd81007, 18'd249313}; // 声像25，高18位左增益，低18位右增益
            5'd26: pan_pair = {18'd67848, 18'd253211}; // 声像26，高18位左增益，低18位右增益
            5'd27: pan_pair = {18'd54503, 18'd256415}; // 声像27，高18位左增益，低18位右增益
            5'd28: pan_pair = {18'd41008, 18'd258916}; // 声像28，高18位左增益，低18位右增益
            5'd29: pan_pair = {18'd27401, 18'd260707}; // 声像29，高18位左增益，低18位右增益
            5'd30: pan_pair = {18'd13720, 18'd261784}; // 声像30，高18位左增益，低18位右增益
            5'd31: pan_pair = {18'd0, 18'd262143}; // 声像31，高18位左增益，低18位右增益
            default: pan_pair = {18'd185363, 18'd185363}; // 默认居中
        endcase
    end
endfunction

function signed [WORK_BITS-1:0] round_product;
    input signed [PRODUCT_BITS-1:0] value; // 带18位系数小数的完整乘积
    reg signed [WORK_BITS:0] integral; // 截去系数小数后，保留一位保护
    reg increment; // 最近整数舍入的加1条件
    begin
        integral = $signed(value[PRODUCT_BITS-1:GAIN_BITS]); // 负数截位等效于向负无穷取整
        increment = value[GAIN_BITS-1] && ((!value[PRODUCT_BITS-1]) || (|value[GAIN_BITS-2:0])); // 正负半LSB均远离零
        integral = integral + (increment ? 1'b1 : 1'b0); // 通过低位判定及一次加1完成对称舍入
        round_product = integral[WORK_BITS-1:0]; // 增益小于1，不会放大到超出原操作数位宽
    end
endfunction

function signed [WORK_BITS-1:0] round_audio;
    input signed [WORK_BITS-1:0] value; // 带4位音频小数的结果
    reg signed [WORK_BITS-1:0] integral; // 去小数后保留保护位
    reg increment; // 最近整数舍入的加1条件
    begin
        integral = value >>> FRAC_BITS; // 算术右移保留符号
        increment = value[FRAC_BITS-1] && ((!value[WORK_BITS-1]) || (|value[FRAC_BITS-2:0])); // 正负半LSB远离零
        round_audio = integral + (increment ? 1'b1 : 1'b0); // 避免绝对值和再次取负的长组合链
    end
endfunction

always @(posedge clk) begin
    if (state == ST_LOAD) begin
        case (operation_index)
            3'd0: begin multiplier_a <= dry_snapshot; multiplier_b <= $signed({1'b0, dry_gain_snapshot}); end // 任务0：公共干声增益
            3'd1: begin multiplier_a <= dry_scaled; multiplier_b <= $signed({1'b0, pan_coefficients[35:18]}); end // 任务1：左干声声像
            3'd2: begin multiplier_a <= dry_scaled; multiplier_b <= $signed({1'b0, pan_coefficients[17:0]}); end // 任务2：右干声声像
            3'd3: begin multiplier_a <= side_value; multiplier_b <= $signed({1'b0, width_snapshot}); end // 任务3：湿声侧分量乘宽度
            3'd4: begin multiplier_a <= wet_left_work; multiplier_b <= $signed({1'b0, wet_gain_snapshot}); end // 任务4：左湿声增益
            3'd5: begin multiplier_a <= wet_right_work; multiplier_b <= $signed({1'b0, wet_gain_snapshot}); end // 任务5：右湿声增益
            3'd6: begin multiplier_a <= mixed_left; multiplier_b <= $signed({1'b0, master_snapshot}); end // 任务6：左总音量
            3'd7: begin multiplier_a <= mixed_right; multiplier_b <= $signed({1'b0, master_snapshot}); end // 任务7：右总音量
        endcase
    end
    if (state == ST_MULTIPLY) multiplier_product <= multiplier_a * multiplier_b; // 唯一通用乘法表达式，物理DSP数量由器件映射决定
    if (state == ST_ROUND) rounded_product <= round_product(multiplier_product); // 独立舍入并寄存，下一拍存入工作状态
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= ST_IDLE; // 复位后直接空闲
        operation_index <= 0; // 清空任务编号
        dry_snapshot <= 0; // 清空干声快照
        wet_l_snapshot <= 0; // 清空左湿声快照
        wet_r_snapshot <= 0; // 清空右湿声快照
        pan_snapshot <= 5'd16; // 默认居中
        dry_gain_snapshot <= 0; // 默认干声静音
        wet_gain_snapshot <= 0; // 默认湿声静音
        width_snapshot <= 0; // 默认宽度为0
        master_snapshot <= 0; // 默认总音量为0
        mid_value <= 0; // 清空中分量
        side_value <= 0; // 清空侧分量
        dry_scaled <= 0; // 清空公共干声
        dry_left <= 0; // 清空左干声
        dry_right <= 0; // 清空右干声
        side_scaled <= 0; // 清空宽度结果
        wet_left_work <= 0; // 清空左湿声
        wet_right_work <= 0; // 清空右湿声
        mixed_left <= 0; // 清空左混合结果
        mixed_right <= 0; // 清空右混合结果
        output_left_rounded <= 0; // 清空待输出左结果
        output_right_rounded <= 0; // 清空待输出右结果
        audio_left <= 0; // 复位左输出静音
        audio_right <= 0; // 复位右输出静音
        out_valid <= 0; // 复位无有效输出
        frame_overrun <= 0; // 清空溢出指示
        clip_detected <= 0; // 清空削波指示
    end else begin
        out_valid <= 1'b0; // 有效脉冲默认只保持一拍
        if (in_valid && busy) frame_overrun <= 1'b1; // 忙时丢弃新帧，保留正在处理的快照
        case (state)
            ST_IDLE: if (in_valid) begin
                dry_snapshot <= $signed({{(WORK_BITS-AUDIO_BITS){dry_in[AUDIO_BITS-1]}}, dry_in}) <<< FRAC_BITS; // 先符号扩位再左移，保留4位内部小数
                wet_l_snapshot <= $signed({{(WORK_BITS-AUDIO_BITS){wet_left_in[AUDIO_BITS-1]}}, wet_left_in}) <<< FRAC_BITS; // 左湿声快照
                wet_r_snapshot <= $signed({{(WORK_BITS-AUDIO_BITS){wet_right_in[AUDIO_BITS-1]}}, wet_right_in}) <<< FRAC_BITS; // 右湿声快照
                pan_snapshot <= dry_pan_select; // 同时锁存声像配置
                dry_gain_snapshot <= dry_gain; // 锁存干声增益
                wet_gain_snapshot <= wet_gain; // 锁存湿声增益
                width_snapshot <= wet_width; // 锁存宽度
                master_snapshot <= master_gain; // 锁存总音量
                operation_index <= 0; // 从任务0开始
                state <= ST_MID_SIDE; // 下一拍计算中侧分量
            end
            ST_MID_SIDE: begin
                mid_value <= (wet_l_snapshot + wet_r_snapshot) >>> 1; // Mid（左右平均），保护位保证求和不溢出
                side_value <= (wet_l_snapshot - wet_r_snapshot) >>> 1; // Side（左右差的一半），内部小数避免丢失半码值
                state <= ST_LOAD; // 准备第0个乘法操作数
            end
            ST_LOAD: state <= ST_MULTIPLY; // 操作数先寄存，下一拍乘法
            ST_MULTIPLY: state <= ST_ROUND; // 完整乘积已寄存
            ST_ROUND: state <= ST_STORE; // 舍入结果已寄存
            ST_STORE: begin
                operation_index <= operation_index + 1'b1; // 下一个任务编号，第7个完成后不再启动
                state <= ST_LOAD; // 默认连续调度下一个乘法
                case (operation_index)
                    3'd0: dry_scaled <= rounded_product; // 保存公共干声
                    3'd1: dry_left <= rounded_product; // 保存左干声
                    3'd2: dry_right <= rounded_product; // 保存右干声
                    3'd3: begin side_scaled <= rounded_product; state <= ST_WIDTH_MIX; end // 宽度乘法完成，下一拍重建左右
                    3'd4: wet_left_work <= rounded_product; // 保存加权左湿声
                    3'd5: begin wet_right_work <= rounded_product; state <= ST_MIX; end // 两路湿声准备好，下一拍干湿相加
                    3'd6: mixed_left <= rounded_product; // 保存左总音量结果
                    3'd7: begin mixed_right <= rounded_product; state <= ST_OUTPUT_ROUND; end // 8次乘法完成
                endcase
            end
            ST_WIDTH_MIX: begin
                wet_left_work <= mid_value + side_scaled; // 左湿声=M+width×S
                wet_right_work <= mid_value - side_scaled; // 右湿声=M-width×S
                state <= ST_LOAD; // 进入任务4
            end
            ST_MIX: begin
                mixed_left <= dry_left + wet_left_work; // 左干湿相加，保留保护位，不提前削波
                mixed_right <= dry_right + wet_right_work; // 右干湿相加，再送总音量
                state <= ST_LOAD; // 进入任务6
            end
            ST_OUTPUT_ROUND: begin
                output_left_rounded <= round_audio(mixed_left); // 去掉内部4位小数并寄存
                output_right_rounded <= round_audio(mixed_right); // 右边采用同一舍入规则
                state <= ST_OUTPUT; // 下一拍范围检查和最终饱和
            end
            ST_OUTPUT: begin
                if (output_left_rounded > audio_max) begin audio_left <= audio_max[AUDIO_BITS-1:0]; clip_detected <= 1'b1; end // 左正溢出饱和
                else if (output_left_rounded < audio_min) begin audio_left <= audio_min[AUDIO_BITS-1:0]; clip_detected <= 1'b1; end // 左负溢出饱和
                else audio_left <= output_left_rounded[AUDIO_BITS-1:0]; // 合法左补码输出
                if (output_right_rounded > audio_max) begin audio_right <= audio_max[AUDIO_BITS-1:0]; clip_detected <= 1'b1; end // 右正溢出饱和
                else if (output_right_rounded < audio_min) begin audio_right <= audio_min[AUDIO_BITS-1:0]; clip_detected <= 1'b1; end // 右负溢出饱和
                else audio_right <= output_right_rounded[AUDIO_BITS-1:0]; // 合法右补码输出
                out_valid <= 1'b1; // 左右同拍发布
                state <= ST_IDLE; // 下一边沿可接受下一帧
            end
            default: begin state <= ST_IDLE; frame_overrun <= 1'b1; end // 非法状态报告错误并取消当前帧
        endcase
    end
end
// synthesis translate_off
initial begin
    if ((GAIN_BITS != 18) || (PAN_BITS != 5) || (AUDIO_BITS < 2) || (AUDIO_BITS > 24)) begin
        $display("ERROR: stereo_output_mixer requires GAIN_BITS=18, PAN_BITS=5 and 2<=AUDIO_BITS<=24");
        $finish;
    end
end
// synthesis translate_on
endmodule

