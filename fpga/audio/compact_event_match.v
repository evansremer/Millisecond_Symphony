module compact_event_match (
input wire [287:0] events, // 每槽18位：年龄9位、鼓号4位、力度5位。
input wire [15:0] valid, latest,
input wire retrigger_only, // DDS/噪声仅执行最新击打；共振执行所有冲激。
input wire [3:0] drum,
input wire [8:0] delay_samples,
output reg found,
output reg [4:0] velocity
);
integer i;
always @* begin
    found=0;velocity=0;
    for(i=0;i<16;i=i+1) begin
        if(valid[i] && (!retrigger_only || latest[i]) && events[i*18+5 +:4]==drum && events[i*18+9 +:9]==delay_samples) begin
            found=1;velocity=velocity | events[i*18 +:5]; // 每采样最多提交一条击打，年龄互异，不存在同年龄多匹配。
        end
    end
end
endmodule
