module video_timing_ctrl #(
    parameter VIDEO_H_LENGTH  = 2200,
    parameter VIDEO_V_LENGTH  = 1125,
    parameter VIDEO_HSYNC_POL = 1,
    parameter VIDEO_HSYNC_LEN = 44,
    parameter VIDEO_HBP_LEN   = 148,
    parameter VIDEO_H_VISIBLE = 1920,
    parameter VIDEO_VSYNC_POL = 1,
    parameter VIDEO_VSYNC_LEN = 5,
    parameter VIDEO_VBP_LEN   = 36,
    parameter VIDEO_V_VISIBLE = 1080
)(
    input  wire        pixel_clock,
    input  wire        reset,
    output wire [13:0] timing_h_pos,
    output wire [13:0] timing_v_pos,
    output wire [13:0] pixel_x,
    output wire [13:0] pixel_y,
    output wire        video_vsync,
    output wire        video_hsync,
    output wire        video_den,
    output wire        video_line_start
);
    localparam H_SYNC_END = VIDEO_HSYNC_LEN - 1;
    localparam H_VIS_BEGIN = VIDEO_HSYNC_LEN + VIDEO_HBP_LEN;
    localparam H_VIS_END = H_VIS_BEGIN + VIDEO_H_VISIBLE - 1;
    localparam V_SYNC_END = VIDEO_VSYNC_LEN - 1;
    localparam V_VIS_BEGIN = VIDEO_VSYNC_LEN + VIDEO_VBP_LEN;
    localparam V_VIS_END = V_VIS_BEGIN + VIDEO_V_VISIBLE - 1;

    reg [13:0] h_pos;
    reg [13:0] v_pos;

    wire h_visible = (h_pos >= H_VIS_BEGIN) && (h_pos <= H_VIS_END);
    wire v_visible = (v_pos >= V_VIS_BEGIN) && (v_pos <= V_VIS_END);
    wire hsync_pos = (h_pos <= H_SYNC_END);
    wire vsync_pos = (v_pos <= V_SYNC_END);

    always @(posedge pixel_clock) begin
        if (reset) begin
            h_pos <= 14'd0;
            v_pos <= 14'd0;
        end else if (h_pos == VIDEO_H_LENGTH - 1) begin
            h_pos <= 14'd0;
            if (v_pos == VIDEO_V_LENGTH - 1)
                v_pos <= 14'd0;
            else
                v_pos <= v_pos + 1'b1;
        end else begin
            h_pos <= h_pos + 1'b1;
        end
    end

    assign timing_h_pos = h_pos;
    assign timing_v_pos = v_pos;
    assign pixel_x = (h_visible && v_visible) ? h_pos - H_VIS_BEGIN : 14'd0;
    assign pixel_y = v_visible ? v_pos - V_VIS_BEGIN : 14'd0;
    assign video_den = h_visible && v_visible;
    assign video_line_start = v_visible && (h_pos == 0);
    assign video_hsync = VIDEO_HSYNC_POL ? hsync_pos : ~hsync_pos;
    assign video_vsync = VIDEO_VSYNC_POL ? vsync_pos : ~vsync_pos;
endmodule
