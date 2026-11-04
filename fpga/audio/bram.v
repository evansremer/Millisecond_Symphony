`timescale 1ns/1ps
`default_nettype none

module reverb_delay_bram #(
    parameter integer DATA_BITS = 32, // Data Bits（存储数据位宽）
    parameter integer ADDR_BITS = 15 // Address Bits（地址位宽），默认32768个样本位置
)(
    input wire clk, // System Clock（读写共用的主时钟）
    input wire write_enable, // Write Enable（写使能），每个clk最多写一个地址
    input wire [ADDR_BITS-1:0] write_address, // Write Address（写入地址）
    input wire signed [DATA_BITS-1:0] write_data, // Write Data（写入的有符号内部状态）
    input wire read_enable, // Read Enable（读使能），地址在上升沿被采样
    input wire [ADDR_BITS-1:0] read_address, // Read Address（读取地址）
    output reg signed [DATA_BITS-1:0] read_data // Read Data（同步读输出），下一上升沿的下游逻辑可使用
);

localparam integer DEPTH = 2**ADDR_BITS; // Memory Depth（容量），深度必须为地址空间的大小
(* ram_style = "block" *) reg signed [DATA_BITS-1:0] delay_mem [0:DEPTH-1]; // Block RAM（块存储器），没有数组复位或异步读端口

always @(posedge clk) begin
    if (write_enable) delay_mem[write_address] <= write_data; // 使用普通写端口完成初始化和反馈状态写回
end

always @(posedge clk) begin
    if (read_enable) read_data <= delay_mem[read_address]; // 同步读取，不增加厂商IP依赖；初次有效读之前不能使用read_data
end

// 控制器必须避免同一上升沿对同一地址同时读写，不依赖RTL与器件的读写碰撞模式差异。
// 本模块故意没有rst_n，外部通过write_enable逐地址清零，以保留BRAM推断结构。
endmodule

`default_nettype wire
