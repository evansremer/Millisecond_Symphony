// One outstanding APB request crosses to the USB clock via a toggle mailbox.
// Payload remains stable until the synchronized acknowledgement returns.
module apb_usb_bridge #(parameter PORT_ID = 1) (
    input pclk, input uclk, input preset_n, ureset_n,
    input [31:0] paddr, pwdata, input [3:0] pstrb,
    input psel, penable, pwrite,
    input [31:0] diagnostic,
    output reg [31:0] prdata, output pready, output reg pslverr,
    output reg awvalid, wvalid, arvalid,
    output [31:0] awaddr, wdata, araddr,
    output [3:0] wstrb,
    input awready, wready, arready, bvalid, rvalid,
    input [1:0] bresp, rresp, input [31:0] rdata,
    output bready, rready
);
    localparam P_IDLE=0, P_WAIT=1, P_DONE=2;
    localparam U_IDLE=0, U_WRITE=1, U_B=2, U_READ=3, U_R=4, U_CAPTURE=5;
    reg [1:0] pstate;
    reg [2:0] ustate;
    reg [31:0] request_addr, request_data, response_data;
    reg [31:0] usb_addr, usb_data;
    reg usb_write;
    reg request_write, request_toggle, ack_toggle, response_error;
    reg [19:0] wait_count;
    (* syn_preserve=1 *) reg ack_meta, ack_sync, req_meta, req_sync;
    (* syn_preserve=1 *) reg [31:0] diag_meta, diag_sync;
    // AE350 requires its external slave response ready while unselected.
    // Holding PREADY low at idle stalled core startup on the physical board.
    assign pready = !psel || pstate == P_DONE;
    assign awaddr = usb_addr;
    assign araddr = usb_addr;
    assign wdata = usb_data;
    assign wstrb = 4'hf; // Core ignores strobes, so reject partial APB writes.
    assign bready = ustate == U_B;
    assign rready = ustate == U_R;

    always @(posedge pclk or negedge preset_n)
    if (!preset_n) begin
        ack_meta<=0; ack_sync<=0; diag_meta<=0; diag_sync<=0;
    end else begin
        ack_meta<=ack_toggle; ack_sync<=ack_meta;
        diag_meta<=diagnostic; diag_sync<=diag_meta;
    end

    always @(posedge pclk or negedge preset_n)
    if (!preset_n) begin
        pstate<=P_IDLE; request_addr<=0; request_data<=0;
        request_write<=0; request_toggle<=0; prdata<=0; pslverr<=0; wait_count<=0;
    end else case (pstate)
        P_IDLE: if (psel && penable) begin
            pslverr<=0;
            if (paddr[23:0] == 24'h0000f0 && !pwrite) begin
                prdata<=32'h554d0201; pstate<=P_DONE;
            end else if (paddr[23:0] == 24'h0000f4 && !pwrite) begin
                // Diagnostic snapshots only; software must not use this
                // asynchronously sampled bundle to make USB protocol decisions.
                prdata<=diag_sync; pstate<=P_DONE;
            end else if (paddr[23:0] == 24'h0000f8 && !pwrite) begin
                prdata<=2; pstate<=P_DONE;
            end else if (paddr[23:0] == 24'h0000fc && !pwrite) begin
                prdata<=PORT_ID; pstate<=P_DONE;
            end else if (ack_sync != request_toggle ||
                         paddr[23:8] != 0 || paddr[7:0]>8'h20 ||
                         paddr[1:0]!=0 || (pwrite && pstrb!=4'hf)) begin
                prdata<=0; pslverr<=1; pstate<=P_DONE;
            end else begin
                request_addr<={24'b0,paddr[7:0]}; request_data<=pwdata;
                request_write<=pwrite; request_toggle<=~request_toggle;
                wait_count<=0; pstate<=P_WAIT;
            end
        end
        P_WAIT: begin
            if (ack_sync == request_toggle) begin
                prdata<=response_data; pslverr<=response_error; pstate<=P_DONE;
            end else if (&wait_count) begin
                // Keep mailbox payload until late ACK; reject new bus accesses
                // until it arrives. Returning error cannot replay a timed out write.
                prdata<=0; pslverr<=1; pstate<=P_DONE;
            end else wait_count<=wait_count+1'b1;
        end
        P_DONE: pstate<=P_IDLE;
        default: pstate<=P_IDLE;
    endcase

    always @(posedge uclk or negedge ureset_n)
    if (!ureset_n) begin req_meta<=0; req_sync<=0; end
    else begin req_meta<=request_toggle; req_sync<=req_meta; end

    always @(posedge uclk or negedge ureset_n)
    if (!ureset_n) begin
        ustate<=U_IDLE; awvalid<=0; wvalid<=0; arvalid<=0;
        response_data<=0; response_error<=0; ack_toggle<=0;
        usb_addr<=0; usb_data<=0; usb_write<=0;
    end else case (ustate)
        U_IDLE: if (req_sync != ack_toggle) begin
            usb_addr<=request_addr; usb_data<=request_data;
            usb_write<=request_write; ustate<=U_CAPTURE;
        end
        U_CAPTURE: begin
            if (usb_write) begin awvalid<=1; wvalid<=1; ustate<=U_WRITE; end
            else begin arvalid<=1; ustate<=U_READ; end
        end
        U_WRITE: begin
            if (awready) awvalid<=0;
            if (wready) wvalid<=0;
            if ((!awvalid || awready) && (!wvalid || wready)) ustate<=U_B;
        end
        U_B: if (bvalid) begin
            response_data<=0; response_error<=|bresp;
            ack_toggle<=req_sync; ustate<=U_IDLE;
        end
        U_READ: if (arready) begin arvalid<=0; ustate<=U_R; end
        U_R: if (rvalid) begin
            response_data<=rdata; response_error<=|rresp;
            ack_toggle<=req_sync; ustate<=U_IDLE;
        end
        default: ustate<=U_IDLE;
    endcase
endmodule
