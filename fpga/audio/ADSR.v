`timescale 1ns/1ps

module adsr_envelope_bank_16 #(
    parameter integer VOICE_COUNT = 16 // Voice Count（声部数量），必须大于0；默认16路独立状态共享一个参数乘法器
)(
    input wire clk, // System Clock（主时钟），全部逻辑都在该时钟域内运行
    input wire rst_n, // Reset（异步低电平复位），系统顶层应同步释放复位
    input wire frame_start, // Frame Start（帧启动），48kHz单clk脉冲，必须在分配器的Gate、力度和配置更新稳定后产生（时钟相位错位处理）
    
    //调度器总线接口
    input wire [VOICE_COUNT-1:0] voice_gate, // Voice Gate（持续按键状态），上升沿触发起音，下降沿触发释放；状态须保持到至少一次成功接收的帧启动
    input wire [VOICE_COUNT*5-1:0] voice_velocity_bus, // Voice Velocity（力度总线），每路5位，只有本帧检测到对应Gate上升沿才采用
    input wire [19:0] adsr_config, // Shared ADSR Configuration（公共配置），[19:15]为A，[14:10]为D，[9:5]为S，[4:0]为R
    
    //乘法器接口
    output reg [VOICE_COUNT*18-1:0] envelope_gain_bus, // Envelope Gain（权重总线），每路18位Q2.16，0为静音，65536为1.0；两帧之间保持不变
    output reg envelope_frame_valid, // Frame Valid（整帧有效），全部声部权重统一发布时拉高一个clk周期
    
    //反回调度器接口
    output reg [VOICE_COUNT-1:0] voice_release_done, // Release Done（释放完成），仅在Release进入OFF的结果发布时产生单clk脉冲，不代表VCA流水已经排空
    
    //测试接口
    output reg busy, // Busy（扫描忙碌），接收启动后为1，结果发布时为0
    output reg frame_overrun // Frame Overrun（帧溢出），busy期间收到frame_start时产生单clk错误脉冲，新请求整体丢弃
);


//位宽计算函数
function integer clog2; // Ceiling Log2（索引位宽计算），至少返回1，支持单声部仿真
    input integer value; // 输入声部数量
    integer remaining; // 右移计数的临时变量
    begin
        remaining = value - 1; // 声部编号最大值为数量减1
        clog2 = 0; // 从零开始统计表示最大编号所需位数
        while (remaining > 0) begin
            remaining = remaining >> 1; // 每次右移消去一位
            clog2 = clog2 + 1; // 增加索引位数
        end
        if (clog2 < 1) clog2 = 1; // 避免VOICE_COUNT为1时出现零宽度向量
    end
endfunction

//位宽计算和状态机本地变量
localparam integer VOICE_INDEX_BITS = clog2(VOICE_COUNT); // 声部索引宽度，不要求声部数量是2的整数次幂
localparam [2:0] ENV_OFF = 3'd0; // OFF（关闭），包络归零但不能单凭本状态回收尚未确认的声部
localparam [2:0] ENV_ATTACK = 3'd1; // Attack（起音），从当前电平上升到本次峰值
localparam [2:0] ENV_DECAY = 3'd2; // Decay（衰减），从起音峰值下降到保持目标
localparam [2:0] ENV_SUSTAIN = 3'd3; // Sustain（保持），按住时保持目标电平，包括保持值为零的情况
localparam [2:0] ENV_RELEASE = 3'd4; // Release（释放），从松键时的电平下降到零
localparam [23:0] ENVELOPE_ONE = 24'd4194304; // Q2.22格式的单位电平1.0，内部额外保留22位小数余量

//线性变化率映射表
function [17:0] time_rate_lut; // Time Rate LUT（时间倒数表），沿用48kHz单声部模块的32档标称时间
    input [4:0] selection; // 时间选择，0立即完成，1～31约为1ms～8s；0档不是零传播延迟
    begin
        case (selection)
            5'd0: time_rate_lut = 18'd0; // 0ms，在该阶段下一次包络递推时直接到达目标
            5'd1: time_rate_lut = 18'd87381; // 1ms
            5'd2: time_rate_lut = 18'd43691; // 2ms
            5'd3: time_rate_lut = 18'd29127; // 3ms
            5'd4: time_rate_lut = 18'd21845; // 4ms
            5'd5: time_rate_lut = 18'd17476; // 5ms
            5'd6: time_rate_lut = 18'd14564; // 6ms
            5'd7: time_rate_lut = 18'd12483; // 7ms
            5'd8: time_rate_lut = 18'd10923; // 8ms
            5'd9: time_rate_lut = 18'd7944; // 11ms
            5'd10: time_rate_lut = 18'd5825; // 15ms
            5'd11: time_rate_lut = 18'd4369; // 20ms
            5'd12: time_rate_lut = 18'd3236; // 27ms
            5'd13: time_rate_lut = 18'd2427; // 36ms
            5'd14: time_rate_lut = 18'd1783; // 49ms
            5'd15: time_rate_lut = 18'd1324; // 66ms
            5'd16: time_rate_lut = 18'd982; // 89ms
            5'd17: time_rate_lut = 18'd722; // 121ms
            5'd18: time_rate_lut = 18'd536; // 163ms
            5'd19: time_rate_lut = 18'd397; // 220ms
            5'd20: time_rate_lut = 18'd295; // 296ms
            5'd21: time_rate_lut = 18'd218; // 400ms
            5'd22: time_rate_lut = 18'd162; // 540ms
            5'd23: time_rate_lut = 18'd120; // 728ms
            5'd24: time_rate_lut = 18'd89; // 983ms
            5'd25: time_rate_lut = 18'd66; // 1326ms
            5'd26: time_rate_lut = 18'd49; // 1789ms
            5'd27: time_rate_lut = 18'd36; // 2414ms
            5'd28: time_rate_lut = 18'd27; // 3257ms
            5'd29: time_rate_lut = 18'd20; // 4394ms
            5'd30: time_rate_lut = 18'd15; // 5929ms
            5'd31: time_rate_lut = 18'd11; // 标称8000ms，倒数定点量化后约7944ms，实际阶段帧数还受起点小数余量影响
            default: time_rate_lut = 18'd0; // 非法仿真值的兜底分支；正常接口不允许X或Z
        endcase
    end
endfunction

reg [2:0] state_bank [0:VOICE_COUNT-1]; // 每个声部独立的ADSR状态
reg [45:0] accumulator_bank [0:VOICE_COUNT-1]; // 每路46位包络累加器，高24位Q2.22，低22位保存小数余量
reg [41:0] increment_bank [0:VOICE_COUNT-1]; // 每路缓存的完整阶段步长，阶段内重复使用，不必重复乘法
reg [23:0] target_bank [0:VOICE_COUNT-1]; // 每路当前阶段目标，采用Q2.22格式
reg [23:0] sustain_bank [0:VOICE_COUNT-1]; // 每路按下时计算并保存的保持目标，不随公共配置直接变化
reg [4:0] decay_bank [0:VOICE_COUNT-1]; // 每路按下时锁存的衰减时间档位
reg [4:0] release_bank [0:VOICE_COUNT-1]; // 每路按下时锁存的释放时间档位
reg [VOICE_COUNT-1:0] instant_bank; // 每路当前阶段是否为0时间档位
reg [VOICE_COUNT-1:0] gate_previous; // 上一次成功接收并处理的帧Gate，用于帧级边沿检测；不是异步同步器
reg [VOICE_COUNT-1:0] gate_snapshot; // 启动时冻结整组Gate，扫描期间外部变化不会修改本帧
reg [VOICE_COUNT*5-1:0] velocity_snapshot; // 启动时冻结16路力度，避免后扫描的声部读取到新帧力度
reg [19:0] config_snapshot; // 启动时冻结公共配置，各声部是否采用由该声部的Gate上升沿决定
reg [VOICE_COUNT*18-1:0] gain_work_bus; // 包络输出工作缓存，避免对外暴露只有部分声部更新的混合帧
reg [VOICE_COUNT-1:0] release_work_mask; // 本帧释放完成位图，扫描结束后与权重一同发布
reg [VOICE_INDEX_BITS-1:0] voice_index; // 当前扫描的声部编号
reg [3:0] slot_index; // 每声部固定16拍，依次执行读取、决策、两次乘法、缓存结果和回写
reg publish_pending; // 最后一声部已写回，下一拍统一发布，确保最后一路也包含在输出帧内
reg [2:0] work_state; // 当前声部工作状态，计算期间不影响其他声部
reg [45:0] work_accumulator; // 当前声部工作累加器，只在普通递推帧前进一步，事件帧保持原值
reg [41:0] work_increment; // 当前声部工作步长
reg [23:0] work_target; // 当前声部工作目标
reg [23:0] work_sustain; // 当前声部工作保持目标
reg [4:0] work_decay; // 当前声部锁存的衰减时间
reg [4:0] work_release; // 当前声部锁存的释放时间
reg work_instant; // 当前工作阶段是否直接到达目标
reg work_rise; // 本帧当前声部是否检测到Gate上升沿
reg work_fall; // 本帧当前声部是否检测到Gate下降沿
reg [23:0] work_velocity_peak; // 本次输入力度对应的Q2.22电平，31档为精确1.0，0～30档为档位/32
reg work_need_sustain; // 本时隙是否需要采用保持目标乘积，只在重新触发时置位
reg work_need_step; // 本时隙是否需要计算并采用新的阶段步长
reg [17:0] work_rate; // 新阶段从时间表取得的归一化变化率
reg work_release_done; // 当前声部是否在本帧从Release进入OFF
reg [23:0] mul_a; // 唯一参数乘法器的24位无符号操作数，复用为力度峰值或阶段电平差
reg [17:0] mul_b; // 唯一参数乘法器的18位无符号操作数，复用为保持档位或时间变化率
reg [41:0] mul_product_reg; // 唯一乘法器的42位寄存结果，在第2拍和第4拍使用同一硬件
wire [41:0] mul_product; // 完整乘积，不在计算阶段步长时截去小数精度
wire [23:0] work_level; // 当前工作累加器的高24位包络电平
wire [45:0] work_target_accumulator; // 当前目标扩展到带22位小数余量的内部格式
wire [45:0] work_increment_extended; // 42位步长补零到46位，以匹配内部累加器
wire [46:0] work_attack_sum; // 起音加法扩展一位，便于先比较后钳位，避免回绕
wire [23:0] work_delta; // 当前工作目标与起点的绝对差，仅在创建新阶段时用于乘法
integer reset_index; // 复位循环变量，综合时展开，不是逐拍扫描计数器

assign mul_product = mul_a * mul_b; // 整个ADSR Bank仅此一处参数乘法，保持目标与阶段步长分时复用，不包含音频加权
assign work_level = work_accumulator[45:22]; // 提取Q2.22包络，内部低22位仍保留
assign work_target_accumulator = {work_target, 22'd0}; // 将目标电平左移22位，对齐内部累加器
assign work_increment_extended = {4'd0, work_increment}; // 步长高位补零，不改变数值
assign work_attack_sum = {1'b0, work_accumulator} + {1'b0, work_increment_extended}; // 无符号扩位相加，结果用于起音目标比较
assign work_delta = (work_target >= work_level) ? (work_target - work_level) : (work_level - work_target); // 只在新阶段启动时计算固定总电平差，不是每帧指数逼近

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        envelope_gain_bus <= {(VOICE_COUNT*18){1'b0}}; // 复位输出静音
        envelope_frame_valid <= 1'b0; // 清除帧发布脉冲
        voice_release_done <= {VOICE_COUNT{1'b0}}; // 复位不是释放完成事件，不发回收通知
        busy <= 1'b0; // 清除扫描忙碌状态
        frame_overrun <= 1'b0; // 清除溢出脉冲
        instant_bank <= {VOICE_COUNT{1'b0}}; // 清除全部零时间阶段标志
        gate_previous <= {VOICE_COUNT{1'b0}}; // 首次采到的高Gate视为新按下
        gate_snapshot <= {VOICE_COUNT{1'b0}}; // 清空本帧Gate快照
        velocity_snapshot <= {(VOICE_COUNT*5){1'b0}}; // 清空力度快照
        config_snapshot <= 20'd0; // 清空公共配置快照
        gain_work_bus <= {(VOICE_COUNT*18){1'b0}}; // 清空尚未发布的权重
        release_work_mask <= {VOICE_COUNT{1'b0}}; // 清空本帧释放记录
        voice_index <= {VOICE_INDEX_BITS{1'b0}}; // 从0号声部开始
        slot_index <= 4'd0; // 从读取时隙开始
        publish_pending <= 1'b0; // 丢弃复位前未发布的结果
        work_state <= ENV_OFF; // 清空当前声部工作状态
        work_accumulator <= 46'd0; // 清空工作累加器
        work_increment <= 42'd0; // 清空工作步长
        work_target <= 24'd0; // 清空工作目标
        work_sustain <= 24'd0; // 清空工作保持目标
        work_decay <= 5'd0; // 清空工作衰减档位
        work_release <= 5'd0; // 清空工作释放档位
        work_instant <= 1'b0; // 清空工作零时间标志
        work_rise <= 1'b0; // 清空上升沿标志
        work_fall <= 1'b0; // 清空下降沿标志
        work_velocity_peak <= 24'd0; // 清空力度峰值
        work_need_sustain <= 1'b0; // 清空保持乘法有效标志
        work_need_step <= 1'b0; // 清空步长乘法有效标志
        work_rate <= 18'd0; // 清空新阶段时间变化率
        work_release_done <= 1'b0; // 清空当前声部释放通知
        mul_a <= 24'd0; // 清空乘法输入A
        mul_b <= 18'd0; // 清空乘法输入B
        mul_product_reg <= 42'd0; // 清空乘法流水结果
        for (reset_index = 0; reset_index < VOICE_COUNT; reset_index = reset_index + 1) begin
            state_bank[reset_index] <= ENV_OFF; // 所有声部进入关闭状态
            accumulator_bank[reset_index] <= 46'd0; // 所有内部包络归零
            increment_bank[reset_index] <= 42'd0; // 所有缓存步长清零
            target_bank[reset_index] <= 24'd0; // 所有阶段目标清零
            sustain_bank[reset_index] <= 24'd0; // 所有保持目标清零
            decay_bank[reset_index] <= 5'd0; // 所有衰减档位清零
            release_bank[reset_index] <= 5'd0; // 所有释放档位清零
        end
    end else begin
        envelope_frame_valid <= 1'b0; // 默认撤销脉冲，对外权重总线本身继续保持
        voice_release_done <= {VOICE_COUNT{1'b0}}; // 释放通知只在发布拍有效，不持续占用
        frame_overrun <= 1'b0; // 溢出信号为脉冲，不是粘滞状态
        if (frame_start && busy) frame_overrun <= 1'b1; // 包含最终发布拍在内，忙碌时的新启动均被拒绝，原快照不受影响
        if (!busy) begin
            if (frame_start) begin
                gate_snapshot <= voice_gate; // 原子冻结本帧全部按键状态，不要求Gate只变化一位
                velocity_snapshot <= voice_velocity_bus; // 原子冻结每个声部独立的力度
                config_snapshot <= adsr_config; // 冻结唯一公共配置，但已经发声的声部仍使用各自锁存参数
                release_work_mask <= {VOICE_COUNT{1'b0}}; // 开始收集本帧释放完成事件
                voice_index <= {VOICE_INDEX_BITS{1'b0}}; // 每帧都按0到VOICE_COUNT-1顺序扫描
                slot_index <= 4'd0; // 接收后的下一拍执行第0时隙
                publish_pending <= 1'b0; // 清除旧发布请求
                busy <= 1'b1; // 接收本次启动并锁定输入快照
            end
        end else if (publish_pending) begin
            envelope_gain_bus <= gain_work_bus; // 在统一边沿发布完整一帧，直到下一帧发布前不改变
            envelope_frame_valid <= 1'b1; // 权重更新与有效脉冲同时产生，后级在下一clk上升沿可采到新数据
            voice_release_done <= release_work_mask; // 完成释放的声部在同一发布边沿通知顶层
            publish_pending <= 1'b0; // 清除发布标志
            busy <= 1'b0; // 本帧完成；从启动接收边沿到此共16*VOICE_COUNT+1个clk
        end else begin
            slot_index <= slot_index + 1'b1; // 固定16拍时隙，不随事件数量改变执行时间
            if (slot_index == 4'd2 || slot_index == 4'd4) mul_product_reg <= mul_product; // 两个时隙通过同一组操作数寄存器和同一个乘法器计算
            case (slot_index)
                4'd0: begin
                    work_state <= state_bank[voice_index]; // 读取当前声部全部独立状态
                    work_accumulator <= accumulator_bank[voice_index]; // 读取高精度当前包络
                    work_increment <= increment_bank[voice_index]; // 读取阶段缓存步长
                    work_target <= target_bank[voice_index]; // 读取阶段目标
                    work_sustain <= sustain_bank[voice_index]; // 读取保持目标
                    work_decay <= decay_bank[voice_index]; // 读取音符锁存的衰减档位
                    work_release <= release_bank[voice_index]; // 读取音符锁存的释放档位
                    work_instant <= instant_bank[voice_index]; // 读取当前阶段零时间标志
                    work_rise <= gate_snapshot[voice_index] && !gate_previous[voice_index]; // 仅比较成功接收的相邻帧Gate，扫描中短脉冲不作为新事件
                    work_fall <= !gate_snapshot[voice_index] && gate_previous[voice_index]; // 检测对应声部松键，优先级高于自然阶段切换
                    work_velocity_peak <= (velocity_snapshot[voice_index*5 +: 5] == 5'd31) ? ENVELOPE_ONE : {2'b00, velocity_snapshot[voice_index*5 +: 5], 17'd0}; // 力度31精确映射1.0，其余档位映射为档位/32
                    work_need_sustain <= 1'b0; // 默认复用缓存保持目标
                    work_need_step <= 1'b0; // 默认复用缓存阶段步长
                    work_release_done <= 1'b0; // 默认本声部没有新释放完成事件
                end
                4'd1: begin
                    if (work_rise) begin
                        work_state <= ENV_ATTACK; // 新按下或重按优先处理，事件帧保持累加器不变，下一帧才推进
                        work_target <= (work_level > work_velocity_peak) ? work_level : work_velocity_peak; // 重按目标取当前电平和新力度峰值的较大者，避免弱力度重按立即下降
                        work_decay <= config_snapshot[14:10]; // 仅按下时锁存D，后续公共配置变化不会改变已有阶段
                        work_release <= config_snapshot[4:0]; // 仅按下时锁存R，抬起时使用这份参数
                        work_rate <= time_rate_lut(config_snapshot[19:15]); // 查询新起音时间
                        work_need_step <= 1'b1; // 起音阶段需要重新计算固定步长
                        work_need_sustain <= 1'b1; // 重按也要基于新力度重新计算保持目标
                        mul_a <= work_velocity_peak; // 第一次乘法的输入A为新力度峰值，而不是重按时较大的当前电平
                        mul_b <= {13'd0, config_snapshot[9:5]}; // 第一次乘法的输入B为保持档位0～31
                    end else if (work_fall && work_state != ENV_OFF) begin
                        work_state <= ENV_RELEASE; // 松键覆盖本帧自然的起音或衰减完成判断
                        work_target <= 24'd0; // 释放目标始终为零
                        work_rate <= time_rate_lut(work_release); // 采用本音符按下时保存的R，而不是最新公共配置
                        work_need_step <= 1'b1; // 从当前电平计算新的释放步长，本帧不使用旧阶段步长
                    end else begin
                        case (work_state)
                            ENV_ATTACK: begin
                                if (work_instant || work_target_accumulator <= work_accumulator || work_attack_sum >= {1'b0, work_target_accumulator}) begin
                                    work_accumulator <= work_target_accumulator; // 到达目标时钳位，不越过力度峰值
                                    work_state <= ENV_DECAY; // 每帧最多推进一个自然阶段，0时间A和D也不会在同一帧连续跳过
                                    work_target <= work_sustain; // 下一阶段目标改为本音符保持电平
                                    work_rate <= time_rate_lut(work_decay); // 采用已锁存的D生成下一阶段步长
                                    work_need_step <= 1'b1; // 在本时隙内缓存衰减步长，供下一帧使用
                                end else work_accumulator <= work_attack_sum[45:0]; // 未到目标时加上固定缓存步长
                            end
                            ENV_DECAY: begin
                                if (work_instant || work_accumulator <= work_target_accumulator || work_accumulator - work_target_accumulator <= work_increment_extended) begin
                                    work_accumulator <= work_target_accumulator; // 到保持目标时钳位，防止减法下溢
                                    work_state <= ENV_SUSTAIN; // 即使保持电平为零，也保持声部状态，不发送释放完成
                                end else work_accumulator <= work_accumulator - work_increment_extended; // 正常衰减只需减法
                            end
                            ENV_SUSTAIN: work_accumulator <= {work_sustain, 22'd0}; // 保持阶段直接维持目标，无需乘法
                            ENV_RELEASE: begin
                                if (work_instant || work_level == 24'd0 || work_accumulator <= work_increment_extended) begin
                                    work_accumulator <= 46'd0; // 释放完成时精确归零，不仅仅截断为零权重
                                    work_state <= ENV_OFF; // 从Release进入OFF是唯一自动发出释放完成通知的路径
                                    work_release_done <= 1'b1; // 暂存当前声部通知，统一发布时再对外输出
                                end else work_accumulator <= work_accumulator - work_increment_extended; // 正常释放只需减法
                            end
                            default: work_accumulator <= 46'd0; // OFF保持零，不产生重复回收通知
                        endcase
                    end
                end
                4'd3: begin
                    if (work_need_sustain) work_sustain <= (config_snapshot[9:5] == 5'd31) ? work_velocity_peak : mul_product_reg[28:5]; // 31档直接采用力度峰值；其余档位将24x5乘积右移5位，保留旧模块的映射规则
                    if (work_need_step) begin
                        mul_a <= work_delta; // 第二次乘法装载新阶段的固定总电平差；自然切换时起点已在第1拍钳位
                        mul_b <= work_rate; // 第二次乘法装载新阶段的时间倒数
                    end
                end
                4'd5: begin
                    if (work_need_step) begin
                        work_increment <= mul_product_reg; // 保存完整24x18位乘积，下一帧按此步长递推
                        work_instant <= (work_rate == 18'd0); // 零时间单独标记，零乘积本身不等于立即完成
                    end
                end
                4'd15: begin
                    state_bank[voice_index] <= work_state; // 固定时隙结束时回写当前声部状态
                    accumulator_bank[voice_index] <= work_accumulator; // 回写46位包络，保留长阶段的小数余量
                    increment_bank[voice_index] <= work_increment; // 回写缓存步长
                    target_bank[voice_index] <= work_target; // 回写当前阶段目标
                    sustain_bank[voice_index] <= work_sustain; // 回写按下时计算的保持目标
                    decay_bank[voice_index] <= work_decay; // 回写该音符的衰减档位
                    release_bank[voice_index] <= work_release; // 回写该音符的释放档位
                    instant_bank[voice_index] <= work_instant; // 回写零时间标志
                    gate_previous[voice_index] <= gate_snapshot[voice_index]; // 已处理的Gate进入历史，丢弃的启动不会推进历史
                    gain_work_bus[voice_index*18 +: 18] <= work_accumulator[45:28]; // 内部Q2.44右移28位得到18位Q2.16，最大65536；音频乘法由外部模块实现
                    release_work_mask[voice_index] <= work_release_done; // 写入本帧释放通知位
                    if (voice_index == VOICE_COUNT - 1) publish_pending <= 1'b1; // 最后一路先写入工作总线，下一拍再发布，避免最后一路落后一帧
                    else voice_index <= voice_index + 1'b1; // 转向下一声部；4位slot_index已经自然回绕到0
                end
                default: begin end // 预留第6～14拍及乘法捕获拍，固定时隙简化验证和未来流水线调整
            endcase
        end
    end
end

endmodule

