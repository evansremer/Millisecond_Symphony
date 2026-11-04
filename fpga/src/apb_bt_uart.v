// 50MHz APB UART, 8N1. Only serial RX is asynchronous. No block RAM/DSP.
// Explicit per-slot flops avoid unsupported distributed-RAM inference on GW5AST.
// RX head is synchronously prefetched; APB DATA pops once.
module apb_bt_uart #(parameter DEFAULT_DIVISOR=434)(
 input clk,reset_n,input rx,output tx,input [7:0] paddr,
 input [31:0] pwdata,input [3:0] pstrb,input psel,penable,pwrite,
 output reg [31:0] prdata,output pready,output pslverr
);
 (* ASYNC_REG="TRUE" *) reg rx_meta,rx_sync;
 reg [15:0] divisor,rx_timer,tx_timer;
 reg [3:0] rx_bit,tx_bit;
 reg [7:0] rx_shift;
 reg [9:0] tx_shift;
 reg rx_busy,tx_busy;
 wire [511:0] rx_storage;
 wire [127:0] tx_storage;
 reg [6:0] rx_head,rx_tail;
 reg [4:0] tx_head,tx_tail;
 reg [7:0] rx_front,tx_front;
 reg [31:0] rx_errors,overruns;
wire [6:0] rx_count=rx_head-rx_tail;
wire [4:0] tx_count=tx_head-tx_tail;
reg tx_prefetched;
wire access=psel && penable;
 wire rx_pop=access && !pwrite && paddr==0 && rx_head!=rx_tail;
 wire tx_push=access && pwrite && paddr==0 && pstrb==4'hf && tx_count!=16;
 wire tx_take=!tx_busy && tx_head!=tx_tail && tx_prefetched;
 wire receive=rx_busy && rx_timer==0 && rx_bit==9 && rx_sync;
 wire rx_room=(rx_count!=64) || rx_pop;
 assign tx=tx_busy?tx_shift[0]:1'b1;
 assign pready=1'b1;
 assign pslverr=access && pwrite && (pstrb!=4'hf || (paddr==0 && tx_count==16));
 genvar slot;
 generate for(slot=0;slot<64;slot=slot+1)begin:rx_slots
  reg [7:0] value;
  always @(posedge clk)if(receive && rx_room && rx_head[5:0]==slot)value<=rx_shift;
  assign rx_storage[slot*8+:8]=value;
 end
 for(slot=0;slot<16;slot=slot+1)begin:tx_slots
  reg [7:0] value;
  always @(posedge clk)if(tx_push && tx_head[3:0]==slot)value<=pwdata[7:0];
  assign tx_storage[slot*8+:8]=value;
 end endgenerate
 wire [5:0] rx_next=rx_tail[5:0]+(rx_pop?6'd1:6'd0);
 wire [3:0] tx_next=tx_tail[3:0]+(tx_take?4'd1:4'd0);
 always @(posedge clk)begin
  rx_front<=rx_storage[rx_next*8+:8];
  tx_front<=tx_storage[tx_next*8+:8];
 end
 always @*case(paddr)
  8'h00:prdata={24'd0,rx_front};
  8'h04:prdata={17'd0,rx_count,4'd0,tx_busy,1'b0,(tx_count!=16),(rx_head!=rx_tail)};
  8'h08:prdata=rx_errors;
  8'h0c:prdata=overruns;
  8'h10:prdata={16'd0,divisor};
  8'hf0:prdata=32'h42540100;
  default:prdata=0;
 endcase
 always @(posedge clk or negedge reset_n)begin
  if(!reset_n)begin
   rx_meta<=1;rx_sync<=1;divisor<=DEFAULT_DIVISOR;tx_prefetched<=0;
   rx_busy<=0;rx_timer<=0;rx_bit<=0;rx_shift<=0;
   tx_busy<=0;tx_timer<=0;tx_bit<=0;tx_shift<=10'h3ff;
   rx_head<=0;rx_tail<=0;tx_head<=0;tx_tail<=0;rx_errors<=0;overruns<=0;
  end else begin
   rx_meta<=rx;rx_sync<=rx_meta;tx_prefetched<=tx_head!=tx_tail && !tx_take;
   if(rx_pop)rx_tail<=rx_tail+1'b1;
   if(receive)begin
    if(rx_room)rx_head<=rx_head+1'b1;else overruns<=overruns+1'b1;
   end
   if(tx_push)tx_head<=tx_head+1'b1;
   if(!rx_busy)begin
    if(!rx_sync)begin rx_busy<=1;rx_timer<=divisor>>1;rx_bit<=0;end
   end else if(rx_timer!=0)rx_timer<=rx_timer-1'b1;
   else begin
    rx_timer<=divisor-1'b1;
    if(rx_bit==0)begin if(rx_sync)rx_busy<=0;else rx_bit<=1;end
    else if(rx_bit==9)begin rx_busy<=0;if(!rx_sync)rx_errors<=rx_errors+1'b1;end
    else begin rx_shift[rx_bit-1'b1]<=rx_sync;rx_bit<=rx_bit+1'b1;end
   end
   if(tx_take)begin
    tx_tail<=tx_tail+1'b1;tx_shift<={1'b1,tx_front,1'b0};
    tx_busy<=1;tx_timer<=divisor-1'b1;tx_bit<=0;
   end else if(tx_busy)begin
    if(tx_timer!=0)tx_timer<=tx_timer-1'b1;
    else begin
     tx_timer<=divisor-1'b1;tx_shift<={1'b1,tx_shift[9:1]};
     if(tx_bit==9)tx_busy<=0;else tx_bit<=tx_bit+1'b1;
    end
   end
   // Baud changes are maintenance-only and discard both queues.
   if(access && pwrite && paddr==8'h10 && pstrb==4'hf && pwdata>=16 && pwdata<=65535 && !rx_busy && !tx_busy)begin
    divisor<=pwdata[15:0];rx_head<=0;rx_tail<=0;tx_head<=0;tx_tail<=0;
   end
  end
 end
endmodule
