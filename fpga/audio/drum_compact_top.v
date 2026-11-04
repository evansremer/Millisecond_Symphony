module drum_compact_top (
input wire clk,rst_n,sample_ce, // 49.152MHz主时钟；48kHz单周期使能，间隔1024拍。
input wire hit_valid,
output wire hit_ready,
input wire [3:0] drum_id,
input wire [4:0] velocity,
output reg [47:0] drum_bus, // [15:0]DDS，[31:16]噪声，[47:32]共振。
output reg drum_bus_valid,
output wire signed [19:0] mixed_sample,
output reg fault,
output reg invalid_hit,
output reg [9:0] cycles_used
);
reg [287:0] events;
reg [15:0] event_valid,event_latest;
reg [3:0] write_slot;
reg pending;reg [8:0] pending_data;
reg launch,started;
reg [31:0] rng;
wire [31:0] rng_a=rng^(rng<<13);
wire [31:0] rng_b=rng_a^(rng_a>>17);
wire [31:0] rng_c=rng_b^(rng_b<<5);
wire signed [18:0] white_value={~rng_c[31],rng_c[30:16],3'b000};
reg signed [23:0] white_now,white_z1,white_z2;
wire env_dds_done,env_noise_done;
wire [3:0] dds_env_address;wire [5:0] noise_env_address;
wire [24:0] dds_env_data,noise_env_data;
wire dds_done,noise_done,modal_done;
wire signed [39:0] dds_sum,noise_sum,modal_sum;
wire noise_overflow,modal_overflow;
reg [2:0] seen;
reg signed [39:0] held_dds,held_noise,held_modal;
reg [9:0] timer;
integer i;
assign hit_ready=rst_n && !fault && !pending && !event_valid[write_slot]; // 一条待接收记录；最多每个采样提交一次击打，支持ready背压。
assign mixed_sample=$signed({{4{drum_bus[15]}},drum_bus[15:0]})+$signed({{4{drum_bus[31]}},drum_bus[31:16]})+$signed({{4{drum_bus[47]}},drum_bus[47:32]});
function signed [15:0] output16;
input signed [39:0] value;
reg signed [39:0] rounded;
begin
    rounded=(value>>>6)+((value[5] && (!value[39] || (|value[4:0])))?40'sd1:40'sd0); // Q18转Q15并固定除8，沿用旧链路余量。
    if(rounded>32767)output16=16'sh7fff;
    else if(rounded < -32768)output16=16'sh8000;
    else output16=rounded[15:0];
end
endfunction
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        events<=0;event_valid<=0;event_latest<=0;write_slot<=0;pending<=0;pending_data<=0;launch<=0;started<=0;rng<=32'd20260915;white_now<=0;white_z1<=0;white_z2<=0;
        seen<=0;held_dds<=0;held_noise<=0;held_modal<=0;timer<=0;cycles_used<=0;fault<=0;invalid_hit<=0;drum_bus<=0;drum_bus_valid<=0;
    end else begin
        launch<=0;drum_bus_valid<=0;invalid_hit<=0;
        if(hit_valid && hit_ready)begin
            if(drum_id>9)invalid_hit<=1;
            else if(velocity!=0)begin pending<=1;pending_data<={drum_id,velocity};end
        end
        if(dds_done)begin held_dds<=dds_sum;seen[0]<=1;end
        if(noise_done)begin held_noise<=noise_sum;seen[1]<=1;end
        if(modal_done)begin held_modal<=modal_sum;seen[2]<=1;end
        if(started && !(&seen))timer<=timer+1'b1;
        if((&(seen|{modal_done,noise_done,dds_done})) && !(&seen))cycles_used<=timer;
        if(noise_overflow || modal_overflow)fault<=1;
        if(sample_ce && !fault)begin
            if(started && !(&seen))fault<=1;
            else begin
                if(started)begin drum_bus<={output16(held_modal),output16(held_noise),output16(held_dds)};drum_bus_valid<=1;end
                started<=1;seen<=0;timer<=0;launch<=1;
                rng<=rng_c;white_now<=white_value;white_z1<=white_now;white_z2<=white_z1;
                for(i=0;i<16;i=i+1)begin
                    if(event_valid[i])begin
                        if(events[i*18+9 +:9]==384)begin event_valid[i]<=0;event_latest[i]<=0;end
                        else events[i*18+9 +:9]<=events[i*18+9 +:9]+1'b1;
                    end
                    if(pending && events[i*18+5 +:4]==pending_data[8:5])event_latest[i]<=0;
                end
                if(pending)begin events[write_slot*18 +:18]<={9'd0,pending_data};event_valid[write_slot]<=1;event_latest[write_slot]<=1;write_slot<=write_slot+1'b1;pending<=0;end
            end
        end
    end
end
compact_envelope #(.LANES(15),.AB(4),.PARAM_FILE("dds_env.mem"),.GAIN_FILE("dds_gain18.mem")) env_dds(
    .clk(clk),.rst_n(rst_n),.start(launch),.events(events),.valid(event_valid),.latest(event_latest),.busy(),.done(env_dds_done),.read_lane(dds_env_address),.read_gain(dds_env_data));
compact_envelope env_noise(.clk(clk),.rst_n(rst_n),.start(launch),.events(events),.valid(event_valid),.latest(event_latest),.busy(),.done(env_noise_done),.read_lane(noise_env_address),.read_gain(noise_env_data));
compact_dds dds(.clk(clk),.rst_n(rst_n),.start(env_dds_done),.envelope_address(dds_env_address),.envelope_data(dds_env_data),.busy(),.done(dds_done),.sum(dds_sum));
compact_iir #(.NOISE(1),.LANES(52),.AB(6),.PARAM_FILE("noise_compact.mem"),.GAIN_FILE("noise_gain18.mem")) noise(
    .clk(clk),.rst_n(rst_n),.start(env_noise_done),.events(events),.valid(event_valid),.latest(event_latest),.white_now(white_now),.white_delay2(white_z2),.envelope_address(noise_env_address),.envelope_data(noise_env_data),.busy(),.done(noise_done),.sum(noise_sum),.overflow(noise_overflow));
compact_iir modal(.clk(clk),.rst_n(rst_n),.start(launch),.events(events),.valid(event_valid),.latest(event_latest),.white_now(24'sd0),.white_delay2(24'sd0),.envelope_address(),.envelope_data(25'd0),.busy(),.done(modal_done),.sum(modal_sum),.overflow(modal_overflow));
endmodule
