`timescale 1ns/1ps
`default_nettype none
// 12 parallel channels per side. Each channel cascades 1..4 allpass sections.
// 30 sections per side, 60 total, all sharing ONE signed25 x signed18 multiplier.
// Output per side = (2*dry + 40*channel0 + 2*sum(channel1..11))/64.
// Visual observer only; do not route these signals back to DAC or FFT.
module lissajous_phase_bank12 (
    input wire clk, rst_n, in_valid,
    input wire signed [23:0] in_left, in_right,
    output reg out_valid,
    output reg signed [23:0] out_left, out_right,
    output wire busy,
    output reg overrun, clipped
);
    localparam [2:0] IDLE=0, READ=1, DELTA=2, MULT=3, STORE=4, MIX=5, OUTPUT=6;
    reg [2:0] state;
    reg [5:0] section;
    reg signed [23:0] input_l, input_r, work_sample;
    (* syn_ramstyle="registers" *) reg signed [23:0] x_history [0:59];
    (* syn_ramstyle="registers" *) reg signed [23:0] y_history [0:59];
    reg signed [23:0] old_x, old_y, y_cache;
    reg signed [17:0] coefficient;
    reg signed [24:0] difference;
    reg signed [42:0] product;
    reg signed [31:0] sum_l, sum_r;
    integer i;
    function signed [17:0] coefficient_at;
        input [5:0] s;
        begin
            case(s)
                6'd0: coefficient_at = -18'sd129791;
                6'd1: coefficient_at = -18'sd125694;
                6'd2: coefficient_at = -18'sd109011;
                6'd3: coefficient_at = -18'sd56313;
                6'd4: coefficient_at = -18'sd128692;
                6'd5: coefficient_at = -18'sd127351;
                6'd6: coefficient_at = -18'sd124807;
                6'd7: coefficient_at = -18'sd125200;
                6'd8: coefficient_at = -18'sd121241;
                6'd9: coefficient_at = -18'sd115251;
                6'd10: coefficient_at = -18'sd122120;
                6'd11: coefficient_at = -18'sd116197;
                6'd12: coefficient_at = -18'sd107396;
                6'd13: coefficient_at = -18'sd94133;
                6'd14: coefficient_at = -18'sd117707;
                6'd15: coefficient_at = -18'sd111206;
                6'd16: coefficient_at = -18'sd98882;
                6'd17: coefficient_at = -18'sd101945;
                6'd18: coefficient_at = -18'sd84754;
                6'd19: coefficient_at = -18'sd61259;
                6'd20: coefficient_at = -18'sd89453;
                6'd21: coefficient_at = -18'sd66299;
                6'd22: coefficient_at = -18'sd35305;
                6'd23: coefficient_at = 18'sd9539;
                6'd24: coefficient_at = -18'sd73404;
                6'd25: coefficient_at = -18'sd54292;
                6'd26: coefficient_at = -18'sd15513;
                6'd27: coefficient_at = -18'sd31468;
                6'd28: coefficient_at = 18'sd19706;
                6'd29: coefficient_at = 18'sd64638;
                6'd30: coefficient_at = -18'sd128692;
                6'd31: coefficient_at = -18'sd120844;
                6'd32: coefficient_at = -18'sd90716;
                6'd33: coefficient_at = -18'sd8591;
                6'd34: coefficient_at = -18'sd126685;
                6'd35: coefficient_at = -18'sd124220;
                6'd36: coefficient_at = -18'sd119628;
                6'd37: coefficient_at = -18'sd120369;
                6'd38: coefficient_at = -18'sd113363;
                6'd39: coefficient_at = -18'sd103051;
                6'd40: coefficient_at = -18'sd114947;
                6'd41: coefficient_at = -18'sd104727;
                6'd42: coefficient_at = -18'sd90083;
                6'd43: coefficient_at = -18'sd68960;
                6'd44: coefficient_at = -18'sd107568;
                6'd45: coefficient_at = -18'sd97210;
                6'd46: coefficient_at = -18'sd77690;
                6'd47: coefficient_at = -18'sd83905;
                6'd48: coefficient_at = -18'sd58254;
                6'd49: coefficient_at = -18'sd23938;
                6'd50: coefficient_at = -18'sd67869;
                6'd51: coefficient_at = -18'sd35213;
                6'd52: coefficient_at = 18'sd9970;
                6'd53: coefficient_at = 18'sd64638;
                6'd54: coefficient_at = -18'sd49332;
                6'd55: coefficient_at = -18'sd30562;
                6'd56: coefficient_at = 18'sd21200;
                6'd57: coefficient_at = -18'sd12909;
                6'd58: coefficient_at = 18'sd52790;
                6'd59: coefficient_at = 18'sd64638;
                default: coefficient_at=18'sd0;
            endcase
        end
    endfunction
    function terminal_at;
        input [5:0] s;
        begin
            case(s)
                6'd3, 6'd4, 6'd6, 6'd9, 6'd13, 6'd14, 6'd16, 6'd19, 6'd23, 6'd24, 6'd26, 6'd29, 6'd33, 6'd34, 6'd36, 6'd39, 6'd43, 6'd44, 6'd46, 6'd49, 6'd53, 6'd54, 6'd56, 6'd59: terminal_at=1'b1;
                default: terminal_at=1'b0;
            endcase
        end
    endfunction
    function signed [23:0] saturate24;
        input signed [42:0] x;
        begin
            if(x>43'sd8388607) saturate24=24'sh7fffff;
            else if(x< -43'sd8388608) saturate24=24'sh800000;
            else saturate24=x[23:0];
        end
    endfunction
    wire signed [23:0] left_scaled=in_left>>>4;
    wire signed [23:0] right_scaled=in_right>>>4;
    wire signed [31:0] left_ext={{8{left_scaled[23]}},left_scaled};
    wire signed [31:0] right_ext={{8{right_scaled[23]}},right_scaled};
    wire terminal=terminal_at(section);
    wire signed [42:0] rounded=(product>>>17)+
        ((product[16] && (!product[42] || (|product[15:0]))) ? 43'sd1 : 43'sd0);
    wire signed [42:0] next_wide=$signed({{19{old_x[23]}},old_x})+rounded;
    wire signed [23:0] next_y=saturate24(next_wide);
    wire signed [31:0] cache_ext={{8{y_cache[23]}},y_cache};
    wire signed [31:0] weighted=(section==6'd3 || section==6'd33) ?
        (cache_ext<<<5)+(cache_ext<<<3) : (cache_ext<<<1);
    // Input /16, mix /64, restored scale: sum /4.
    wire signed [42:0] final_l=$signed({{11{sum_l[31]}},sum_l})>>>2;
    wire signed [42:0] final_r=$signed({{11{sum_r[31]}},sum_r})>>>2;
    assign busy=(state!=IDLE);

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;section<=0;input_l<=0;input_r<=0;work_sample<=0;
            old_x<=0;old_y<=0;y_cache<=0;coefficient<=0;difference<=0;product<=0;
            sum_l<=0;sum_r<=0;out_left<=0;out_right<=0;
            out_valid<=0;overrun<=0;clipped<=0;
            for(i=0;i<60;i=i+1) begin x_history[i]<=0;y_history[i]<=0;end
        end else begin
            out_valid<=0;
            if(in_valid && busy) overrun<=1;
            case(state)
                IDLE: if(in_valid) begin
                    input_l<=left_scaled;input_r<=right_scaled;work_sample<=left_scaled;
                    sum_l<=left_ext<<<1;sum_r<=right_ext<<<1;
                    section<=0;state<=READ;
                end
                READ: begin
                    old_x<=x_history[section];old_y<=y_history[section];
                    coefficient<=coefficient_at(section);state<=DELTA;
                end
                DELTA: begin
                    difference<=$signed({work_sample[23],work_sample})-$signed({old_y[23],old_y});
                    state<=MULT;
                end
                MULT: begin product<=difference*coefficient;state<=STORE;end
                STORE: begin
                    x_history[section]<=work_sample;y_history[section]<=next_y;y_cache<=next_y;
                    if(next_wide>43'sd8388607 || next_wide< -43'sd8388608) clipped<=1;
                    if(terminal) begin
                        if(section==6'd29 || section>=6'd30) work_sample<=input_r;
                        else work_sample<=input_l;
                    end else work_sample<=next_y;
                    state<=MIX;
                end
                MIX: begin
                    if(terminal) begin
                        if(section<6'd30) sum_l<=sum_l+weighted;
                        else sum_r<=sum_r+weighted;
                    end
                    if(section==6'd59) state<=OUTPUT;
                    else begin section<=section+1'b1;state<=READ;end
                end
                OUTPUT: begin
                    out_left<=saturate24(final_l);out_right<=saturate24(final_r);
                    if(final_l>43'sd8388607 || final_l< -43'sd8388608 ||
                       final_r>43'sd8388607 || final_r< -43'sd8388608) clipped<=1;
                    out_valid<=1;state<=IDLE;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
