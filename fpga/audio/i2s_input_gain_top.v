`timescale 1ns/1ps
`default_nettype none
module i2s_input_gain_top (
    input wire clk, rst_n, // 49.152MHz主时钟；异步低有效复位，要求在clk域同步释放
    input wire sample_ce, // 48kHz单周期提交使能；不是新时钟
    input wire i2s_bck, i2s_lrck, i2s_din, // I2S位时钟、左右选择、ADC串行数据
    input wire [17:0] gain_left, gain_right, // 无符号Q6.12增益；必须已同步到clk域
    output reg [33:0] sample_bus, // [16:0]人声、[33:17]吉他；两次sample_ce之间保持稳定
    output reg sample_valid, // 提交新双声道帧时脉冲；无新帧则保留原输出，不重复置有效
    output reg [1:0] clipped, // 随sample_valid有效；bit0左削顶、bit1右削顶
    output wire gain_busy, // 共用乘法流水正在计算
    output wire gain_overrun, // 计算忙时又有新输入帧：拒收新帧，报警一个clk
    output wire format_error, // 检测到左右时隙长度不是32BCK，报警一个clk
    output reg pending_overrun // 未提交结果被新结果覆盖，报警一个clk
);
    wire signed [23:0] rx_left, rx_right;
    wire rx_valid, gain_valid;
    wire [33:0] gain_bus;
    wire [1:0] gain_clipped;
    reg pending;
    reg [33:0] pending_bus;
    reg [1:0] pending_clipped;
    i2s_rx24_stereo u_rx (
        .clk(clk),.rst_n(rst_n),.i2s_bck(i2s_bck),.i2s_lrck(i2s_lrck),.i2s_din(i2s_din),
        .pcm_left(rx_left),.pcm_right(rx_right),.frame_valid(rx_valid),.format_error(format_error)
    );
    stereo_gain24_to17 u_gain (
        .clk(clk),.rst_n(rst_n),.in_valid(rx_valid),.pcm_left(rx_left),.pcm_right(rx_right),
        .gain_left(gain_left),.gain_right(gain_right),.sample_bus(gain_bus),.out_valid(gain_valid),
        .busy(gain_busy),.overrun(gain_overrun),.clipped(gain_clipped)
    );
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_bus<=0; sample_valid<=0; clipped<=0;
            pending<=0; pending_bus<=0; pending_clipped<=0; pending_overrun<=0;
        end else begin
            sample_valid<=0; pending_overrun<=0;
            if (sample_ce) begin
                // Prefer the newest complete pair on exact arrival/commit coincidence.
                if (gain_valid) begin
                    sample_bus<=gain_bus; clipped<=gain_clipped; sample_valid<=1;
                    pending_overrun<=pending;
                end else if (pending) begin
                    sample_bus<=pending_bus; clipped<=pending_clipped; sample_valid<=1;
                end
                pending<=0;
            end else if (gain_valid) begin
                pending_overrun<=pending;
                pending_bus<=gain_bus; pending_clipped<=gain_clipped; pending<=1;
            end
        end
    end
endmodule
`default_nettype wire
