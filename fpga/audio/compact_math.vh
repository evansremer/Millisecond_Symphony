// 24位状态与必要保护位；所有舍入采用最近整数，半LSB远离零。
function signed [23:0] sat24;
input signed [49:0] value;
begin
    if(value>50'sd8388607) sat24=24'sh7fffff;
    else if(value < -50'sd8388608) sat24=24'sh800000;
    else sat24=value[23:0];
end
endfunction
function signed [49:0] round22;
input signed [49:0] value;
begin round22=(value>>>22)+((value[21] && (!value[49] || (|value[20:0])))?50'sd1:50'sd0); end
endfunction
function signed [49:0] round15;
input signed [49:0] value;
begin round15=(value>>>15)+((value[14] && (!value[49] || (|value[13:0])))?50'sd1:50'sd0); end
endfunction
function signed [49:0] round18;
input signed [49:0] value;
begin round18=(value>>>18)+((value[17] && (!value[49] || (|value[16:0])))?50'sd1:50'sd0); end
endfunction
