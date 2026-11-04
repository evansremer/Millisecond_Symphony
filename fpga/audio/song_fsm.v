`timescale 1ns/1ps
`default_nettype none
// -----------------------------------------------------------------------------
// song_fsm —— 单键触发的 24 秒演示，纯状态机，不使用 ROM / .mem。
//
//   按下板载按键（低有效）→ 依次演示三种音色 + 鼓，播放中再按一下立即停止。
//
//   段落安排：
//     1  圆号  (instrument=01)  小星星前两句   6.4 s
//     2  钢琴  (instrument=00)  同上           6.4 s
//     3  合成器(instrument=10)  同上           6.4 s
//     4  鼓    (drum_id 轮换)   8 击 @0.5 s    4.0 s
//     段间留 0.4 s 静默，让旧乐器尾音自然衰减（切换乐器不会硬切尾音）。
//     合计约 24 s，控制在 30 s 以内。
//
//   时长单位：48 kHz 采样点。四分音符 = 19200（0.4 s），二分 = 38400（0.8 s）。
//   每个音符末尾留 10 ms 释放间隙，重复音靠它重新触发。
//
//   同 phase 输出当前段落（0 圆号 / 1 钢琴 / 2 合成器 / 3 鼓），供界面显示。
// -----------------------------------------------------------------------------
module song_fsm(
    input  wire        clk,               // 49.152 MHz 音频主时钟
    input  wire        rst_n,
    input  wire        tick_48k,          // 48 kHz 单周期使能
    input  wire        key_n,             // 板载按键，低有效
    output reg  [31:0] key_state,
    output reg  [4:0]  velocity,
    output wire [1:0]  instrument_select, // 随段落自动切换
    output reg  [3:0]  drum_id,
    output reg  [4:0]  drum_velocity,
    output reg         drum_valid,
    input  wire        drum_ready,
    output reg         playing,
    output reg  [4:0]  note_index,
    output reg         note_on,
    output reg         note_kick,
    output reg  [1:0]  phase
);

    // ---- 时间与谱面参数 -----------------------------------------------------
    localparam [15:0] QUARTER    = 16'd19200;  // 0.4 s
    localparam [15:0] HALF       = 16'd38400;  // 0.8 s
    localparam [15:0] GAP_TICKS  = 16'd480;    // 10 ms 释放间隙
    localparam [15:0] PAUSE      = 16'd19200;  // 段间静默 0.4 s
    localparam [15:0] DRUM_GAP   = 16'd24000;  // 鼓间隔 0.5 s
    localparam [15:0] DRUM_LEAD  = 16'd6000;   // 进入鼓段后的首击延迟
    localparam [4:0]  LAST_NOTE  = 5'd13;      // 14 个音符，索引 0..13
    localparam [3:0]  DRUM_N     = 4'd8;
    localparam [4:0]  VELOCITY   = 5'd22;
    localparam [4:0]  DRUM_VEL   = 5'd31;

    localparam [2:0] S_IDLE = 3'd0, S_NOTE = 3'd1, S_PAUSE = 3'd2,
                     S_DRUM = 3'd3, S_DONE = 3'd4;

    // ---- 小星星前两句：C C G G A A G— F F E E D D C—（16 个四分单位）------
    function [20:0] note_at;
        input [4:0] i;
        begin
            case (i)
                5'd0 : note_at = {5'd19, QUARTER}; // C4
                5'd1 : note_at = {5'd19, QUARTER}; // C4
                5'd2 : note_at = {5'd26, QUARTER}; // G4
                5'd3 : note_at = {5'd26, QUARTER}; // G4
                5'd4 : note_at = {5'd28, QUARTER}; // A4
                5'd5 : note_at = {5'd28, QUARTER}; // A4
                5'd6 : note_at = {5'd26, HALF   }; // G4 二分
                5'd7 : note_at = {5'd24, QUARTER}; // F4
                5'd8 : note_at = {5'd24, QUARTER}; // F4
                5'd9 : note_at = {5'd23, QUARTER}; // E4
                5'd10: note_at = {5'd23, QUARTER}; // E4
                5'd11: note_at = {5'd21, QUARTER}; // D4
                5'd12: note_at = {5'd21, QUARTER}; // D4
                5'd13: note_at = {5'd19, HALF   }; // C4 二分
                default: note_at = {5'd19, QUARTER};
            endcase
        end
    endfunction

    // ---- 鼓音色轮换 ---------------------------------------------------------
    function [3:0] drum_at;
        input [3:0] i;
        begin
            case (i)
                4'd0: drum_at = 4'd0;
                4'd1: drum_at = 4'd2;
                4'd2: drum_at = 4'd4;
                4'd3: drum_at = 4'd6;
                4'd4: drum_at = 4'd8;
                4'd5: drum_at = 4'd5;
                4'd6: drum_at = 4'd3;
                default: drum_at = 4'd9;
            endcase
        end
    endfunction

    // ---- 段落 → 乐器 --------------------------------------------------------
    assign instrument_select = (phase == 2'd0) ? 2'b01 :   // 圆号
                               (phase == 2'd1) ? 2'b00 :   // 钢琴
                                                 2'b10;    // 合成器

    wire [20:0] cur     = note_at(note_ptr);
    wire [4:0]  cur_idx = cur[20:16];
    wire [15:0] cur_dur = cur[15:0];
    wire [15:0] on_dur  = cur_dur - GAP_TICKS;

    reg [2:0]  state;
    reg [4:0]  note_ptr;
    reg [15:0] dur_cnt;
    reg [15:0] pause_cnt;

    reg [3:0]  drum_ptr;
    reg [15:0] drum_timer;
    reg [1:0]  drum_hold;
    reg        drum_state;

    // ---- 1 ms 时基与按键消抖 ------------------------------------------------
    reg [15:0] ms_div;
    reg        ms_tick;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ms_div  <= 16'd0;
            ms_tick <= 1'b0;
        end else if (ms_div == 16'd49151) begin
            ms_div  <= 16'd0;
            ms_tick <= 1'b1;
        end else begin
            ms_div  <= ms_div + 1'b1;
            ms_tick <= 1'b0;
        end
    end

    reg  [1:0] key_sync;
    reg  [1:0] db_cnt;
    reg        key_stable;
    reg        key_stable_d;
    wire       key_raw   = ~key_sync[1];
    wire       key_press = key_stable & ~key_stable_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_sync     <= 2'b11;
            db_cnt       <= 2'd0;
            key_stable   <= 1'b0;
            key_stable_d <= 1'b0;
        end else begin
            key_sync     <= {key_sync[0], key_n};
            key_stable_d <= key_stable;
            if (ms_tick) begin
                if (key_raw) begin
                    if (db_cnt == 2'd3) key_stable <= 1'b1;
                    else                db_cnt     <= db_cnt + 1'b1;
                end else begin
                    db_cnt     <= 2'd0;
                    key_stable <= 1'b0;
                end
            end
        end
    end

    // ---- 播放状态机 ---------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            phase      <= 2'd0;
            note_ptr   <= 5'd0;
            dur_cnt    <= 16'd0;
            pause_cnt  <= 16'd0;
            drum_ptr   <= 4'd0;
            drum_timer <= 16'd0;
            drum_hold  <= 2'd0;
            drum_state <= 1'b0;
            key_state  <= 32'd0;
            velocity   <= 5'd0;
            drum_id    <= 4'd0;
            drum_velocity <= 5'd0;
            drum_valid <= 1'b0;
            playing    <= 1'b0;
            note_index <= 5'd0;
            note_on    <= 1'b0;
            note_kick  <= 1'b0;
        end else begin
            note_kick <= 1'b0;

            case (state)
                // -------- 等待按键 --------
                S_IDLE: begin
                    key_state <= 32'd0;
                    note_on   <= 1'b0;
                    playing   <= 1'b0;
                    velocity  <= 5'd0;
                    drum_valid<= 1'b0;
                    if (key_press) begin
                        phase      <= 2'd0;
                        note_ptr   <= 5'd0;
                        dur_cnt    <= 16'd0;
                        playing    <= 1'b1;
                        velocity   <= VELOCITY;
                        state      <= S_NOTE;
                    end
                end

                // -------- 逐音符推进 --------
                S_NOTE: begin
                    if (key_press) begin
                        playing   <= 1'b0;
                        key_state <= 32'd0;
                        note_on   <= 1'b0;
                        state     <= S_DONE;
                    end else if (tick_48k) begin
                        if (dur_cnt < on_dur) begin
                            key_state <= (32'd1 << cur_idx);
                            note_on   <= 1'b1;
                        end else begin
                            key_state <= 32'd0;
                            note_on   <= 1'b0;
                        end

                        if (dur_cnt == cur_dur - 16'd1) begin
                            dur_cnt <= 16'd0;
                            if (note_ptr == LAST_NOTE) begin
                                key_state <= 32'd0;
                                note_on   <= 1'b0;
                                if (phase == 2'd2) begin
                                    // 三种音色演完 → 进鼓段
                                    phase      <= 2'd3;
                                    drum_ptr   <= 4'd0;
                                    drum_timer <= DRUM_LEAD;
                                    drum_hold  <= 2'd0;
                                    drum_state <= 1'b0;
                                    state      <= S_DRUM;
                                end else begin
                                    phase     <= phase + 2'd1;
                                    pause_cnt <= PAUSE;
                                    state     <= S_PAUSE;
                                end
                            end else begin
                                note_ptr   <= note_ptr + 5'd1;
                                note_index <= note_at(note_ptr + 5'd1)[20:16];
                                note_kick  <= 1'b1;
                            end
                        end else begin
                            dur_cnt <= dur_cnt + 16'd1;
                        end
                    end
                end

                // -------- 段间静默，让旧乐器尾音衰减 --------
                S_PAUSE: begin
                    key_state <= 32'd0;
                    note_on   <= 1'b0;
                    if (key_press) begin
                        playing <= 1'b0;
                        state   <= S_DONE;
                    end else if (tick_48k) begin
                        if (pause_cnt == 16'd0) begin
                            note_ptr <= 5'd0;
                            dur_cnt  <= 16'd0;
                            state    <= S_NOTE;
                        end else begin
                            pause_cnt <= pause_cnt - 16'd1;
                        end
                    end
                end

                // -------- 鼓段：8 击，每击把 valid 拉高三个 tick --------
                S_DRUM: begin
                    key_state <= 32'd0;
                    note_on   <= 1'b0;
                    if (key_press) begin
                        playing    <= 1'b0;
                        drum_valid <= 1'b0;
                        state      <= S_DONE;
                    end else if (tick_48k) begin
                        if (drum_state == 1'b0) begin
                            drum_valid <= 1'b0;
                            if (drum_timer != 16'd0) begin
                                drum_timer <= drum_timer - 16'd1;
                            end else if (drum_ptr != DRUM_N && drum_ready) begin
                                drum_id       <= drum_at(drum_ptr);
                                drum_velocity <= DRUM_VEL;
                                drum_valid    <= 1'b1;
                                drum_hold     <= 2'd3;
                                drum_state    <= 1'b1;
                            end else if (drum_ptr == DRUM_N) begin
                                playing <= 1'b0;
                                state   <= S_DONE;
                            end
                        end else begin
                            drum_valid <= 1'b1;
                            if (drum_hold != 2'd0) begin
                                drum_hold <= drum_hold - 2'd1;
                            end else begin
                                drum_valid <= 1'b0;
                                drum_ptr   <= drum_ptr + 4'd1;
                                drum_timer <= DRUM_GAP;
                                drum_state <= 1'b0;
                            end
                        end
                    end
                end

                // -------- 收尾：等按键松开 --------
                S_DONE: begin
                    key_state  <= 32'd0;
                    note_on    <= 1'b0;
                    playing    <= 1'b0;
                    velocity   <= 5'd0;
                    drum_valid <= 1'b0;
                    if (!key_stable) state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire
