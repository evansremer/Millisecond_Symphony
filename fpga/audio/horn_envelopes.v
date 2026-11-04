// Independent fitted horn envelope: 8 PWL attack knots, indefinite sustain,
// exponential note-off tails. This is NOT the ordinary synthesizer ADSR.
module horn_envelopes(
input wire clk,rst_n,start,
input wire [15:0] active,gate,strike,
input wire [79:0] keys,velocities,
input wire [287:0] voice_ratios,
output reg done,
output reg [15:0] quiet,
output wire [111:0] parameter_ids,table_ids,
output wire [511:0] phases,
output wire [863:0] envelopes,
output wire [1199:0] releases,
output wire [399:0] transients,
output wire [287:0] velocity_gains,
output wire [383:0] whites
);
// Word arrays plus constant packing avoid synthesizing arbitrary bit-position
// barrel shifters for the large shared buses. Numeric representation is unchanged.
reg [6:0] parameter_id_words[0:15],table_id_words[0:15];
reg [31:0] phase_words[0:15];
reg [17:0] env0_words[0:15],env1_words[0:15],env2_words[0:15];
reg [24:0] release0_words[0:15],release1_words[0:15],release2_words[0:15],transient_words[0:15];
reg [17:0] velocity_words[0:15];
reg [23:0] white_words[0:15];
wire [4:0] key_words[0:15],input_velocity_words[0:15];
genvar g;
generate for(g=0;g<16;g=g+1)begin:pack_words
 assign key_words[g]=keys[g*5 +:5];
 assign input_velocity_words[g]=velocities[g*5 +:5];
 assign parameter_ids[g*7 +:7]=parameter_id_words[g];
 assign table_ids[g*7 +:7]=table_id_words[g];
 assign phases[g*32 +:32]=phase_words[g];
 assign envelopes[g*54 +:54]={env2_words[g],env1_words[g],env0_words[g]};
 assign releases[g*75 +:75]={release2_words[g],release1_words[g],release0_words[g]};
 assign transients[g*25 +:25]=transient_words[g];
 assign velocity_gains[g*18 +:18]=velocity_words[g];
 assign whites[g*24 +:24]=white_words[g];
end endgenerate
(* rom_style="block" *) reg [135:0] meta[0:127];
(* rom_style="block" *) reg [149:0] env_rom[0:1023];
reg [135:0] mq; reg [149:0] eq;
reg [31:0] phase_state[0:15];
reg [15:0] ages[0:15],release_ages[0:15];
reg [24:0] body_r[0:15],modal_r[0:15],noise_r[0:15],slow[0:15],fast[0:15];
reg [3:0] voice;reg [3:0] state;
reg [6:0] pid; reg [2:0] segment;
reg [15:0] age,offset;
reg [24:0] br,mr,nr,sl,fa;
reg [31:0] rng;
// The scheduler outputs and the selected voice remain stable for the whole
// envelope pass.  Capture the per-voice control decisions in state 3, which
// was already an arithmetic pipeline stage, so state 4 no longer contains the
// long voice-decode -> release-age compare -> output-word mux path.  This does
// not add a state or change done/output timing.
reg expired_q,gate_q,strike_q;
reg [4:0] vel_q;
wire [31:0] ra=rng^(rng<<13), rb=ra^(ra>>17), rc=rb^(rb<<5);
wire signed [23:0] raw_white={rc[31],rc[31:9]};
wire signed [23:0] scaled_white=(raw_white>>>1)-(raw_white>>>4)-(raw_white>>>8);
wire [4:0] vel=input_velocity_words[voice];
wire [6:0] selected_pid=(vel<=10?7'd0:(vel<=22?7'd32:7'd64))+{2'b0,key_words[voice]};
reg [49:0] bent_step;
reg signed [48:0] ep0,ep1,ep2;
reg [51:0] bp,mp,np,sp,fp;
reg [17:0] base0,base1,base2;
wire [24:0] next_br=gate_q?25'd16777216:(bp>>26);
wire [24:0] next_mr=gate_q?25'd16777216:(mp>>26);
wire [24:0] next_nr=gate_q?25'd16777216:(np>>26);
integer j;
initial begin $readmemh("horn_meta.mem",meta);$readmemh("horn_envelope.mem",env_rom);end
always @* begin
    if(age<576)begin segment=0;offset=age;end
    else if(age<1440)begin segment=1;offset=age-576;end
    else if(age<2880)begin segment=2;offset=age-1440;end
    else if(age<5280)begin segment=3;offset=age-2880;end
    else if(age<9600)begin segment=4;offset=age-5280;end
    else if(age<16800)begin segment=5;offset=age-9600;end
    else if(age<28800)begin segment=6;offset=age-16800;end
    else begin segment=7;offset=0;end
end
always @(posedge clk)begin
    if(state==1)mq<=meta[selected_pid];
    if(state==2)eq<=env_rom[{pid,segment}];
    if(state==3)begin
        bent_step<=mq[38:7]*18'd131072;
        ep0<=$signed(eq[49:18])*$signed({1'b0,offset});
        ep1<=$signed(eq[99:68])*$signed({1'b0,offset});
        ep2<=$signed(eq[149:118])*$signed({1'b0,offset});
        base0<=eq[17:0];base1<=eq[67:50];base2<=eq[117:100];
        bp<=br*mq[65:39];mp<=mr*mq[92:66];np<=nr*mq[119:93];
        sp<=sl*27'd67085566;fp<=fa*27'd66911092;
    end
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
    state<=0;voice<=0;done<=0;quiet<=16'hffff;
    pid<=0;age<=0;br<=0;mr<=0;nr<=0;sl<=0;fa<=0;rng<=32'h5a19753d;
    expired_q<=1'b1;gate_q<=1'b0;strike_q<=1'b0;vel_q<=5'd0;
    for(j=0;j<16;j=j+1)begin phase_state[j]<=0;ages[j]<=0;release_ages[j]<=0;
      parameter_id_words[j]<=0;table_id_words[j]<=0;phase_words[j]<=0;
      env0_words[j]<=0;env1_words[j]<=0;env2_words[j]<=0;
      release0_words[j]<=0;release1_words[j]<=0;release2_words[j]<=0;
      transient_words[j]<=0;velocity_words[j]<=0;white_words[j]<=0;
      body_r[j]<=0;modal_r[j]<=0;noise_r[j]<=0;slow[j]<=0;fast[j]<=0;end
 end else begin
    done<=0;
    case(state)
    0:if(start)begin voice<=0;state<=1;end
    1:begin
      pid<=selected_pid;age<=strike[voice]?16'd0:ages[voice];
      br<=strike[voice]?25'd16777216:body_r[voice];
      mr<=strike[voice]?25'd16777216:modal_r[voice];nr<=strike[voice]?25'd16777216:noise_r[voice];
      sl<=strike[voice]?25'd16777216:slow[voice];fa<=strike[voice]?25'd16777216:fast[voice];
      state<=2;
    end
    2:state<=3;
    3:begin
      expired_q<=!active[voice] || (!gate[voice] && release_ages[voice]>=mq[135:120]);
      gate_q<=gate[voice];strike_q<=strike[voice];vel_q<=vel;
      state<=4;
    end
    4:begin
      parameter_id_words[voice]<=pid;table_id_words[voice]<=mq[6:0];
      phase_words[voice]<=strike_q?32'd0:phase_state[voice];
      phase_state[voice]<=(strike_q?32'd0:phase_state[voice])+(bent_step>>17);
      env0_words[voice]<=base0+(ep0>>>10);
      env1_words[voice]<=base1+(ep1>>>10);
      env2_words[voice]<=base2+(ep2>>>10);
      release0_words[voice]<=expired_q?25'd0:(gate_q?25'd16777216:br);
      release1_words[voice]<=expired_q?25'd0:(gate_q?25'd16777216:mr);
      release2_words[voice]<=expired_q?25'd0:(gate_q?25'd16777216:nr);
      transient_words[voice]<=sl>=fa?sl-fa:25'd0;
      velocity_words[voice]<=vel_q==31?18'd65536:({13'd0,vel_q}*18'd2114);
      rng<=rc;white_words[voice]<=scaled_white;
      quiet[voice]<=expired_q;
      if(strike_q || gate_q)release_ages[voice]<=0;
      else if(release_ages[voice]!=65535)release_ages[voice]<=release_ages[voice]+1'b1;
      if(gate_q && age<28800)ages[voice]<=age+1'b1;else ages[voice]<=age;
      body_r[voice]<=expired_q?25'd0:next_br;modal_r[voice]<=expired_q?25'd0:next_mr;noise_r[voice]<=expired_q?25'd0:next_nr;
      slow[voice]<=sp>>26;fast[voice]<=fp>>26;
      if(voice==15)begin state<=0;done<=1;end else begin voice<=voice+1'b1;state<=1;end
    end
    default:state<=0;
    endcase
 end
end
endmodule
