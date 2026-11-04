// One shared synchronous waveform ROM and serialized interpolating DDS.
// The accepted offline dictionary uses ten basis timbres.  Each original
// table/band selects two bases plus an 8-bit convex mix coefficient.
module horn_body(
input wire clk,rst_n,start,
input wire [111:0] table_ids,
input wire [511:0] phases,
input wire [863:0] envelopes,
input wire [1199:0] releases,
input wire [287:0] velocity_gains,
output reg done,
output reg signed [35:0] sum
);
// Ten bases x three bands x 512 samples = 15,360 used words.  Padding to 16K
// fits one depth bank, i.e. sixteen 1-bit-wide Gowin pROM slices.
reg signed [15:0] wave_rom[0:16383] /* synthesis syn_romstyle="block_rom" */;
// 65 original table IDs x three bands.  This is parameter metadata, not an
// audio wavetable; keep it in distributed ROM so it does not consume BSRAM.
reg [16:0] map_rom[0:255] /* synthesis syn_romstyle="distributed_rom" */;
reg signed [15:0] a0,a1,b0,b1;
reg [4:0] state;reg [3:0] voice;reg [1:0] band;
// Statically unpack words before selecting a voice. Gowin otherwise builds
// large generic bit-shifters for non-power-of-two packed-bus strides.
wire [31:0] phase_words[0:15];
wire [6:0] tid_words[0:15];
wire [17:0] env0_words[0:15],env1_words[0:15],env2_words[0:15],vel_words[0:15];
wire [24:0] rel_words[0:15];
genvar g;
generate for(g=0;g<16;g=g+1)begin:unpack
 assign phase_words[g]=phases[g*32+:32];
 assign tid_words[g]=table_ids[g*7+:7];
 assign env0_words[g]=envelopes[g*54+:18];
 assign env1_words[g]=envelopes[g*54+18+:18];
 assign env2_words[g]=envelopes[g*54+36+:18];
 assign vel_words[g]=velocity_gains[g*18+:18];
 assign rel_words[g]=releases[g*75+:25];
end endgenerate
wire [31:0] phase=phase_words[voice];
wire [6:0] tid=tid_words[voice];
wire [8:0] index=phase[31:23];
wire [8:0] next_index=index+9'd1;

// The current mapping is registered for the complete voice/band pass.  The
// asynchronous lookup port is shared between start-up and following-band
// prefetch, avoiding replicated multi-port mapping logic.
reg [16:0] map_q,map_prefetch;
reg [1:0] band_prefetch;reg [8:0] index_prefetch;
wire [3:0] following_voice=(band==2'd2)?(voice+1'b1):voice;
wire [1:0] following_band=(band==2'd2)?2'd0:(band+1'b1);
wire [31:0] following_phase=phase_words[following_voice];
wire [6:0] following_tid=tid_words[following_voice];
wire lookup_start=(state==4'd0);
wire [6:0] lookup_tid=lookup_start?tid_words[0]:following_tid;
wire [1:0] lookup_band=lookup_start?2'd0:following_band;
wire [31:0] lookup_phase=lookup_start?phase_words[0]:following_phase;
wire [7:0] lookup_map_address={1'b0,lookup_tid}+({1'b0,lookup_tid}<<1)+{6'd0,lookup_band};
reg [7:0] lookup_address_q;
wire [16:0] lookup_map=map_rom[lookup_address_q];
wire [3:0] lookup_basis_a=lookup_map[15:12];
wire [4:0] lookup_slot_a={1'b0,lookup_basis_a}+({1'b0,lookup_basis_a}<<1)+{3'd0,lookup_band};
wire [4:0] prefetched_slot={1'b0,map_prefetch[15:12]}+({1'b0,map_prefetch[15:12]}<<1)+{3'd0,band_prefetch};
wire [13:0] prefetched_address={prefetched_slot,index_prefetch};

wire current_zero=map_q[16];
wire [3:0] current_basis_a=map_q[15:12];
wire [3:0] current_basis_b=map_q[11:8];
wire [7:0] current_mix=map_q[7:0];
wire [4:0] current_slot_a={1'b0,current_basis_a}+({1'b0,current_basis_a}<<1)+{3'd0,band};
wire [4:0] current_slot_b={1'b0,current_basis_b}+({1'b0,current_basis_b}<<1)+{3'd0,band};
wire [13:0] current_a_next_address={current_slot_a,9'd0}+{5'd0,next_index};
wire [13:0] current_b_address={current_slot_b,9'd0}+{5'd0,index};
wire [13:0] current_b_next_address={current_slot_b,9'd0}+{5'd0,next_index};
reg [13:0] rom_address;
wire [17:0] env=band==0?env0_words[voice]:(band==1?env1_words[voice]:env2_words[voice]);
wire [24:0] rel=rel_words[voice];
wire [17:0] vel=vel_words[voice];
reg signed [25:0] interpolation_a,interpolation_b;
reg signed [16:0] wave_a,wave_b;
reg signed [26:0] morph_product;
reg signed [16:0] wave;
reg signed [35:0] ep;
reg signed [23:0] env_audio;
reg signed [49:0] rp;
reg signed [42:0] vp;
reg signed [35:0] accum;
initial begin
    $readmemh("horn_wave_10basis.mem",wave_rom);
    $readmemh("horn_10basis_map.mem",map_rom);
end
always @(posedge clk)begin
    if((state==0 && start) || state==11)begin
        lookup_address_q<=lookup_map_address;band_prefetch<=lookup_band;index_prefetch<=lookup_phase[31:23];
    end
    if(state==15 || state==12)map_prefetch<=lookup_map;
    if(state==16)begin map_q<=map_prefetch;rom_address<=prefetched_address;end
    if(state==1)begin
        a0<=current_zero?16'sd0:wave_rom[rom_address];
        rom_address<=current_a_next_address;
    end
    if(state==2)begin
        a1<=current_zero?16'sd0:wave_rom[rom_address];
        rom_address<=current_b_address;
    end
    if(state==3)begin
        b0<=current_zero?16'sd0:wave_rom[rom_address];
        rom_address<=current_b_next_address;
    end
    if(state==4)b1<=current_zero?16'sd0:wave_rom[rom_address];
    if(state==5)interpolation_a<=($signed({a1[15],a1})-$signed({a0[15],a0}))*$signed({1'b0,phase[22:15]});
    if(state==6)begin
        wave_a<=$signed({a0[15],a0})+(interpolation_a>>>8);
        interpolation_b<=($signed({b1[15],b1})-$signed({b0[15],b0}))*$signed({1'b0,phase[22:15]});
    end
    if(state==7)wave_b<=$signed({b0[15],b0})+(interpolation_b>>>8);
    if(state==8)morph_product<=($signed({wave_b[16],wave_b})-$signed({wave_a[16],wave_a}))*$signed({1'b0,current_mix});
    if(state==9)wave<=wave_a+(morph_product>>>8);
    if(state==10)ep<=wave*$signed({1'b0,env});
    if(state==11)env_audio<=ep>>>16;
    if(state==12)rp<=env_audio*$signed({1'b0,rel});
    if(state==13)vp<=$signed(rp[47:24])*$signed({1'b0,vel});
    if(state==14 && !((band==2'd2)&&(voice==4'd15)))begin
        map_q<=map_prefetch;
        rom_address<=prefetched_address;
    end
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=0;voice<=0;band<=0;done<=0;sum<=0;accum<=0;end
 else begin
    done<=0;
    case(state)
    0:if(start)begin state<=15;voice<=0;band<=0;accum<=0;end
    15:state<=16;16:state<=1;
    1:state<=2;2:state<=3;3:state<=4;4:state<=5;5:state<=6;6:state<=7;7:state<=8;
    8:state<=9;9:state<=10;10:state<=11;11:state<=12;12:state<=13;13:state<=14;
    14:begin
      accum<=accum+(vp>>>16);
      if(band==2)begin
        band<=0;
        if(voice==15)begin sum<=accum+(vp>>>16);state<=0;done<=1;end
        else begin voice<=voice+1'b1;state<=1;end
      end else begin band<=band+1'b1;state<=1;end
    end
    default:state<=0;
    endcase
 end
end
endmodule
