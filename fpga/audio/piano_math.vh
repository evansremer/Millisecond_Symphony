// Fixed-point helpers. Constant shift arguments are folded by synthesis.
// Q21 states: signed 24 bit; Q26 rotation/filter coefficients: signed 28 bit.
function signed [52:0] p_round;
input signed [52:0] value;
input integer shift;
reg [52:0] mask;
reg increment;
begin
    mask=(53'd1<<(shift-1))-1'b1;
    increment=value[shift-1] && (!value[52] || ((value & mask)!=0));
    p_round=(value>>>shift)+(increment?53'sd1:53'sd0);
end
endfunction
function signed [52:0] p_trunc;
input signed [52:0] value;
input integer shift;
reg [52:0] mask;
begin
    mask=(53'd1<<shift)-1'b1;
    p_trunc=(value>>>shift)+((value[52] && ((value & mask)!=0))?53'sd1:53'sd0);
end
endfunction
function signed [23:0] p_sat24;
input signed [52:0] value;
begin
    if(value>53'sd8388607)p_sat24=24'sh7fffff;
    else if(value < -53'sd8388608)p_sat24=24'sh800000;
    else p_sat24=value[23:0];
end
endfunction
function p_clip24;
input signed [52:0] value;
begin p_clip24=(value>53'sd8388607 || value < -53'sd8388608);end
endfunction
function [24:0] p_abs24;
input signed [23:0] value;
begin p_abs24=value[23] ? -$signed({value[23],value}):{1'b0,value};end
endfunction
