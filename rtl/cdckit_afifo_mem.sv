// -----------------------------------------------------------------------------
// cdckit_afifo_mem.sv
// Simple dual-port distributed RAM of the asynchronous FIFO
// -----------------------------------------------------------------------------
module cdckit_afifo_mem #(
  parameter int unsigned  DATA_W = 72,
  parameter int unsigned  DEPTH  = 32,
  localparam int unsigned AW     = unsigned'($clog2(DEPTH))
) (
  input  logic              wclk_i,
  input  logic              we_i,
  input  logic [AW-1:0]     waddr_i,
  input  logic [DATA_W-1:0] wdata_i,
  input  logic [AW-1:0]     raddr_i,
  output logic [DATA_W-1:0] rdata_o
);

  (* RAM_STYLE = "distributed" *) // [MAS-AF-7] [PERF-9]
  logic [DATA_W-1:0] mem_q [DEPTH];

  always_ff @(posedge wclk_i) begin // [RST-2]
    if (we_i) begin
      mem_q[waddr_i] <= wdata_i;
    end
  end

  assign rdata_o = mem_q[raddr_i]; // [MAS-AF-7]

endmodule : cdckit_afifo_mem
