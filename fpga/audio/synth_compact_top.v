// 32-voice, four ROM-waveform DDS plus the original ADSR envelope bank.
// Keyboard bits 0..31 = MIDI 41..72 (F2..C5). 48 kHz, 1024 clocks/frame.
// timbre_select: 00 sine, 01 square, 10 triangle, 11 saw; latched on note-on.
// ALL waveforms use a synchronous 8192 x 16 ROM. No waveform arithmetic.
// Each 32-voice frame computes in < 800 clocks; publishes on the following sample_ce.
module synth_compact_top #(
    parameter integer VOICE_COUNT = 32,
    parameter integer HEADROOM_BITS = 2,
    parameter WAVE_FILE = "synth_wave.mem",
    parameter PHASE_FILE = "synth_phase.mem"
)(
    input wire clk, rst_n, sample_ce,
    input wire [159:0] note_bus,velocity_values,
input wire [127:0] channel_values,
input wire [287:0] channel_ratios,
input wire [31:0] key_state,
    input wire [4:0] velocity_value,
    input wire [1:0] timbre_select,
    input wire [19:0] adsr_config,
    output reg signed [18:0] audio_sample,
    output reg frame_valid,
    output wire [VOICE_COUNT-1:0] voice_active,output wire [31:0] active_notes,
    output wire busy,
    output reg fault
);
// A[19:15], D[14:10], S[9:5], R[4:0], matching the original ADSR bank.
// Snapshot all controls at sample_ce; the bank then retains per-note parameters.
// Horn is independent.
reg [159:0] sampled_notes,sampled_velocities;
reg [127:0] sampled_channels;
reg launch, started, computed;
reg [31:0] sampled_keys;
reg [4:0] sampled_velocity;
reg [1:0] sampled_timbre;
reg [19:0] sampled_adsr_config;
wire scheduler_done;
wire [VOICE_COUNT-1:0] active, gate, strike, fresh, quiet;
wire [VOICE_COUNT*5-1:0] keys, velocities;
reg [31:0] observed_notes;integer observe_i;
always @* begin observed_notes=0;for(observe_i=0;observe_i<VOICE_COUNT;observe_i=observe_i+1) if(active[observe_i])observed_notes=observed_notes | (32'd1 << keys[observe_i*5+:5]);end
assign active_notes=observed_notes;
assign voice_active=active;

wire [VOICE_COUNT*4-1:0] voice_channels;
wire [VOICE_COUNT*18-1:0] voice_ratios;
genvar bend_voice;
generate for(bend_voice=0;bend_voice<VOICE_COUNT;bend_voice=bend_voice+1)begin:select_bend
 assign voice_ratios[bend_voice*18+:18]=18'd131072;
end endgenerate
wire [VOICE_COUNT*18-1:0] gains;
wire env_valid, env_busy, env_overrun;
wire [31:0] rejected_keys;
reg [31:0] phases [0:VOICE_COUNT-1];
reg [1:0] wave_bank [0:VOICE_COUNT-1];
reg signed [15:0] wave_rom [0:8191];
reg [31:0] phase_rom [0:31];
reg [12:0] wave_addr;
reg [4:0] phase_addr;
reg signed [15:0] wave_q;
reg [31:0] step_q;
reg [$clog2(VOICE_COUNT)-1:0] voice_index;
reg [2:0] state;
reg [17:0] gain_q;
reg [49:0] bent_step;
reg signed [34:0] product_q;
reg signed [23:0] sum_work, sum_hold;
wire signed [18:0] voice_sample = product_q[34:16]; // Exact signed Q16 removal.
wire signed [23:0] scaled_sum = sum_hold >>> HEADROOM_BITS;
integer k;
genvar g;
generate for (g = 0; g < VOICE_COUNT; g = g + 1) begin: voice_quiet
    assign quiet[g] = !gate[g] && (gains[g*18 +: 18] == 0);
end endgenerate
initial begin
    $readmemh(WAVE_FILE, wave_rom);
    $readmemh(PHASE_FILE, phase_rom);
end
// Read ports remain clocked without reset for block-ROM inference.
always @(posedge clk) begin
    wave_q <= wave_rom[wave_addr];
    step_q <= phase_rom[phase_addr];
end
assign busy = started && !computed;
function signed [18:0] sat19;
    input signed [23:0] x;
    begin
        if (x > 24'sd262143) sat19 = 19'sh3ffff;
        else if (x < -24'sd262144) sat19 = 19'sh40000;
        else sat19 = x[18:0];
    end
endfunction
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        launch <= 0; started <= 0; computed <= 0;
        sampled_keys <= 0; sampled_velocity <= 0; sampled_timbre <= 0;
        sampled_adsr_config <= 0;
        audio_sample <= 0; frame_valid <= 0; fault <= 0;
        wave_addr <= 0; phase_addr <= 0; voice_index <= 0; state <= 0;
        gain_q <= 0; product_q <= 0; sum_work <= 0; sum_hold <= 0;
        for (k = 0; k < VOICE_COUNT; k = k + 1) begin
            phases[k] <= 0;
            wave_bank[k] <= 0;
        end
    end else begin
        launch <= 0;
        frame_valid <= 0;
        if (env_overrun) fault <= 1;
        if (scheduler_done) begin
            for (k = 0; k < VOICE_COUNT; k = k + 1)
                if (strike[k]) wave_bank[k] <= sampled_timbre;
        end
        if (sample_ce && !fault) begin
            if (started && !computed) fault <= 1;
            else begin
                if (started) begin
                    audio_sample <= sat19(scaled_sum);
                    frame_valid <= 1;
                end
                sampled_keys <= key_state;sampled_notes<=note_bus;sampled_velocities<=velocity_values;sampled_channels<=channel_values;
                sampled_velocity <= velocity_value;
                sampled_timbre <= timbre_select;
                sampled_adsr_config <= adsr_config;
                launch <= 1;
                started <= 1;
                computed <= 0;
            end
        end
        case (state)
            0: if (env_valid) begin
                voice_index <= 0;
                sum_work <= 0;
                state <= 1;
            end
            1: begin
                // New/repeated notes begin at phase zero, all other notes continue.
                wave_addr <= {wave_bank[voice_index],
                              (strike[voice_index] ? 11'd0 : phases[voice_index][31:21])};
                phase_addr <= keys[voice_index*5 +: 5];
                gain_q <= active[voice_index] ? gains[voice_index*18 +: 18] : 18'd0;
                state <= 2;
            end
            2: state <= 6;
            6: begin bent_step<=step_q*18'd131072;state<=3;end // // Synchronous ROM read latency.
            3: begin
                // One time-shared signed 16 x 19 VCA multiplier.
                product_q <= $signed(wave_q) * $signed({1'b0, gain_q});
                if (active[voice_index])
                    phases[voice_index] <= strike[voice_index] ? (bent_step>>17) : phases[voice_index] + (bent_step>>17);
                state <= 4;
            end
            4: begin
                sum_work <= sum_work + {{5{voice_sample[18]}}, voice_sample};
                if (voice_index == VOICE_COUNT-1) state <= 5;
                else begin
                    voice_index <= voice_index + 1'b1;
                    state <= 1;
                end
            end
            5: begin
                sum_hold <= sum_work;
                computed <= 1;
                state <= 0;
            end
            default: state <= 0;
        endcase
    end
end
piano_scheduler #(.VOICE_COUNT(VOICE_COUNT)) scheduler(
    .clk(clk), .rst_n(rst_n), .start(launch), .key_state(sampled_keys),
    .velocity_value(sampled_velocity), .note_bus(sampled_notes),.velocity_values(sampled_velocities),.channel_values(sampled_channels),.voice_channels(voice_channels),.modal_quiet(quiet), .noise_quiet(quiet),
    .busy(), .done(scheduler_done), .active(active), .gate(gate), .strike(strike),
    .fresh(fresh), .settled(), .key_bus(keys), .velocity_bus(velocities),
    .damp_bus(), .rejected_keys(rejected_keys)
);
adsr_envelope_bank_16 #(.VOICE_COUNT(VOICE_COUNT)) envelopes (
    .clk(clk), .rst_n(rst_n), .frame_start(scheduler_done), .voice_gate(gate),
    .voice_velocity_bus(velocities), .adsr_config(sampled_adsr_config),
    .envelope_gain_bus(gains), .envelope_frame_valid(env_valid),
    .voice_release_done(), .busy(env_busy), .frame_overrun(env_overrun)
);
endmodule
