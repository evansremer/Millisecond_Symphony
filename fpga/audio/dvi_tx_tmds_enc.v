module dvi_tx_tmds_enc(
    input  wire       clock,
    input  wire       reset,
    input  wire       den,
    input  wire [7:0] data,
    input  wire [1:0] ctrl,
    output reg  [9:0] tmds
);
    reg        den_reg;
    reg  [1:0] ctrl_reg;
    reg signed [8:0] disparity;
    reg signed [8:0] disparity_next;
    reg  [9:0] output_code;
    wire [8:0] q_m_pre;
    reg [8:0] q_m;
    wire       use_xnor;
    wire [3:0] input_ones;
    wire [3:0] qm_ones;
    wire signed [8:0] balance = $signed({4'd0, qm_ones, 1'b0}) - 9'sd8;
    reg signed [8:0] disparity_step;

    function [3:0] count_ones;
        input [7:0] value;
        reg [1:0] a,b,c,d;
        reg [2:0] ab,cd;
        begin
            a={1'b0,value[0]}+{1'b0,value[1]};
            b={1'b0,value[2]}+{1'b0,value[3]};
            c={1'b0,value[4]}+{1'b0,value[5]};
            d={1'b0,value[6]}+{1'b0,value[7]};
            ab={1'b0,a}+{1'b0,b};cd={1'b0,c}+{1'b0,d};
            count_ones={1'b0,ab}+{1'b0,cd};
        end
    endfunction

    assign input_ones = count_ones(data);
    assign use_xnor = (input_ones > 4) || ((input_ones == 4) && !data[0]);
    assign q_m_pre[0] = data[0];
    // Parallel prefix parity: XNOR contributes one inversion at odd indices.
    // This is the exact original code, with the same register latency.
    assign q_m_pre[1] = (^data[1:0]) ^ use_xnor;
    assign q_m_pre[2] = ^data[2:0];
    assign q_m_pre[3] = (^data[3:0]) ^ use_xnor;
    assign q_m_pre[4] = ^data[4:0];
    assign q_m_pre[5] = (^data[5:0]) ^ use_xnor;
    assign q_m_pre[6] = ^data[6:0];
    assign q_m_pre[7] = (^data[7:0]) ^ use_xnor;
    assign q_m_pre[8] = ~use_xnor;
    assign qm_ones = count_ones(q_m[7:0]);

    always @(*) begin
        output_code = 10'b1101010100;
        disparity_next = disparity;
        disparity_step = 9'sd0;

        if (!den_reg) begin
            disparity_next = 9'sd0;
            case (ctrl_reg)
                2'b00: output_code = 10'b1101010100;
                2'b01: output_code = 10'b0010101011;
                2'b10: output_code = 10'b0101010100;
                2'b11: output_code = 10'b1010101011;
            endcase
        end else if ((disparity == 0) || (qm_ones == 4)) begin
            output_code[9] = ~q_m[8];
            output_code[8] = q_m[8];
            output_code[7:0] = q_m[8] ? q_m[7:0] : ~q_m[7:0];
            if (q_m[8])
                disparity_step = balance;
            else
                disparity_step = -balance;
        end else if (((disparity > 0) && (qm_ones > 4)) ||
                     ((disparity < 0) && (qm_ones < 4))) begin
            output_code = {1'b1, q_m[8], ~q_m[7:0]};
            if (q_m[8])
                disparity_step = 9'sd2 - balance;
            else
                disparity_step = -balance;
        end else begin
            output_code = {1'b0, q_m[8], q_m[7:0]};
            if (!q_m[8])
                disparity_step = balance - 9'sd2;
            else
                disparity_step = balance;
        end
        if (den_reg) disparity_next = disparity + disparity_step;
    end

    always @(posedge clock) begin
        if (reset) begin
            // Zero input encodes to 9'h100 in the first stage.
            q_m <= 9'h100;
            den_reg <= 1'b0;
            ctrl_reg <= 2'b00;
            tmds <= 10'd0;
            disparity <= 9'sd0;
        end else begin
            // Retiming across the existing input register adds no pixel delay.
            q_m <= q_m_pre;
            den_reg <= den;
            ctrl_reg <= ctrl;
            tmds <= output_code;
            disparity <= disparity_next;
        end
    end
endmodule
