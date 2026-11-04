//IIS对应协议
/*
* 当前i2s_bclk为1，翻转后变成0，
* 因此这里对应BCLK下降沿。
*
* PCM5102在BCLK上升沿采样DIN，
* FPGA在下降沿改变DIN。
*/

module i2s_tx_simple #(
    parameter integer SAMPLE_BITS    = 24, // PCM有效位数
    parameter integer SLOT_BITS      = 32, // 每声道占用的BCLK数量
    parameter integer BCLK_HALF_DIV  = 16  // BCLK半周期分频数
)(
    input  wire                       clk,
    input  wire                       rst_n,
    // 顶层始终提供下一帧左右声道样本
    input  wire [SAMPLE_BITS-1:0]     pcm_left,
    input  wire [SAMPLE_BITS-1:0]     pcm_right,
    // 每个立体声帧产生一个clk周期脉冲
    output reg                        sample_ce,
    // 连接PCM5102
    output reg                        i2s_bclk,
    output reg                        i2s_lrclk,
    output reg                        i2s_din
);

//位宽计算函数
    function integer clog2;
        input integer value;
        integer temp;
        begin
            temp  = value - 1;
            clog2 = 0;
            while (temp > 0) begin
                temp  = temp >> 1;
                clog2 = clog2 + 1;
            end
            if (clog2 < 1)
                clog2 = 1;
        end
    endfunction
    
//计算对应的位宽
    localparam integer DIV_CNT_BITS = clog2(BCLK_HALF_DIV);
    localparam integer BIT_CNT_BITS = clog2(SLOT_BITS);
    localparam integer PAD_BITS     = SLOT_BITS - SAMPLE_BITS;
    
//相关缓冲器
    //bclk分频计数
    reg [DIV_CNT_BITS-1:0] bclk_div_cnt;
    //bit发送位，寄存器
    reg [BIT_CNT_BITS-1:0] bit_cnt;
    //当前数据寄存器
    reg [SLOT_BITS-1:0] shift_reg;         //这两个寄存器需要根据格式存入数据
    //右通道寄存
    reg [SLOT_BITS-1:0] right_data_reg;

    //输入数据预先整形
    wire [SLOT_BITS-1:0] pcm_left_slot;  
    wire [SLOT_BITS-1:0] pcm_right_slot;
    assign pcm_left_slot = {
        pcm_left,
        {PAD_BITS{1'b0}}
    };
    assign pcm_right_slot = {
        pcm_right,
        {PAD_BITS{1'b0}}
    };
    
    
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bclk_div_cnt  <= {DIV_CNT_BITS{1'b0}};
            bit_cnt       <= SLOT_BITS - 1;
            shift_reg     <= {SLOT_BITS{1'b0}};
            right_data_reg <= {SLOT_BITS{1'b0}};
            /*
             * 初始处于右声道末尾状态。
             * 第一个BCLK下降沿之后进入左声道。
             */
            i2s_bclk      <= 1'b0;
            i2s_lrclk     <= 1'b1;
            i2s_din       <= 1'b0;
            sample_ce     <= 1'b0;
        end
        else begin
            
            //默认拉低
            sample_ce <= 1'b0;
            
            if (bclk_div_cnt == BCLK_HALF_DIV - 1) begin      //这里是位更新的触发点
                bclk_div_cnt <= {DIV_CNT_BITS{1'b0}};
                /*
                 * 翻转BCLK
                 */
                i2s_bclk <= ~i2s_bclk; //时钟分频
                
                if (i2s_bclk == 1'b1) begin      //上升沿
                    
                    //发送移位寄存器最高位，MSB first。（左对齐）
                    i2s_din <= shift_reg[SLOT_BITS-1];
                    if (bit_cnt == SLOT_BITS - 1) begin
                        /*
                         * 当前声道最后一位已经送出。
                         */
                        bit_cnt <= {BIT_CNT_BITS{1'b0}};

                        if (i2s_lrclk == 1'b0) begin
                            /*
                             * 左声道发送结束。
                             *
                             * 在发送左声道LSB的下降沿，
                             * LRCLK提前切换到右声道。
                             *
                             * 下一个BCLK下降沿才发送右声道MSB，
                             * 从而形成标准I2S的一位延迟。
                             */
                            i2s_lrclk <= 1'b1;
                            shift_reg <= right_data_reg;
                        end
                        else begin
                            /*
                             * 右声道发送结束，新一帧开始。
                             */
                            i2s_lrclk <= 1'b0;
                            /*
                             * 锁存顶层提供的下一帧数据。
                             */
                            shift_reg      <= pcm_left_slot;
                            right_data_reg <= pcm_right_slot;
                            /*
                             * 通知顶层准备下一帧音频数据。
                             */
                            sample_ce <= 1'b1;
                        end
                    end
                    else begin
                        /*
                         * 继续发送当前声道的下一位。
                         */
                        bit_cnt <= bit_cnt + 1'b1;
                        shift_reg <= {shift_reg[SLOT_BITS-2:0], 1'b0}; //此处为移位
                    end
                end
            end
            else begin
                bclk_div_cnt <= bclk_div_cnt + 1'b1;
            end
        end
    end

endmodule