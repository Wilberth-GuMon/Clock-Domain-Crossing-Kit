// -----------------------------------------------------------------------------
// cdckit_afifo.sv
// Asynchronous FIFO with Gray pointers, FWFT semantics and conservative flags
// -----------------------------------------------------------------------------
module cdckit_afifo #(
  parameter int unsigned  DATA_W               = 72,
  parameter int unsigned  DEPTH                = 32,
  parameter int unsigned  NUM_STAGES           = 2,
  parameter int unsigned  AF_THRESH            = (DEPTH > 4) ? DEPTH - 4 : DEPTH - 1,
  parameter int unsigned  AE_THRESH            = 2,
  parameter bit           OUTPUT_ZERO_IF_EMPTY = 1'b0,
  localparam int unsigned AW                   = unsigned'($clog2(DEPTH)),
  localparam int unsigned PTR_W                = AW + 1 // [MAS-AF-1]
) (
  // Write port
  input  logic              wclk_i,
  input  logic              wrst_ni,
  input  logic              wr_en_i,
  input  logic [DATA_W-1:0] wr_data_i,
  output logic              full_o,
  output logic              almost_full_o,
  output logic [PTR_W-1:0]  wr_level_o,
  output logic              wr_overflow_o,
  // Read port
  input  logic              rclk_i,
  input  logic              rrst_ni,
  input  logic              rd_en_i,
  output logic [DATA_W-1:0] rd_data_o,
  output logic              empty_o,
  output logic              almost_empty_o,
  output logic [PTR_W-1:0]  rd_level_o,
  output logic              rd_underflow_o
);

  // ---------------------------------------------------------------------------
  // Parameter checks
  // ---------------------------------------------------------------------------
  if (DEPTH < 4 || (DEPTH & (DEPTH - 1)) != 0) begin : g_err_depth // [PARAM-1]
    $fatal(1, "cdckit_afifo: DEPTH = %0d must be a power of 2 and >= 4", DEPTH);
  end
  if (AF_THRESH < 1 || AF_THRESH > DEPTH) begin : g_err_af // [PARAM-3]
    $fatal(1, "cdckit_afifo: AF_THRESH = %0d out of range [1:%0d]", AF_THRESH, DEPTH);
  end
  if (AE_THRESH > DEPTH - 1) begin : g_err_ae // [PARAM-3]
    $fatal(1, "cdckit_afifo: AE_THRESH = %0d out of range [0:%0d]", AE_THRESH, DEPTH - 1);
  end
  if (DATA_W == 0) begin : g_err_data_w // [PARAM-4]
    $fatal(1, "cdckit_afifo: DATA_W must be >= 1");
  end

  logic              mem_we;
  logic [AW-1:0]     waddr, raddr;
  logic [DATA_W-1:0] mem_rdata;
  logic [PTR_W-1:0]  wgray, rgray;
  logic [PTR_W-1:0]  wq2_rgray, rq2_wgray;

  // ---------------------------------------------------------------------------
  // Write domain
  // ---------------------------------------------------------------------------
  cdckit_afifo_wptr #(
    .DEPTH     (DEPTH),
    .AF_THRESH (AF_THRESH)
  ) u_wptr (
    .wclk_i        (wclk_i),
    .wrst_ni       (wrst_ni),
    .wr_en_i       (wr_en_i),
    .wq2_rgray_i   (wq2_rgray),
    .mem_we_o      (mem_we),
    .waddr_o       (waddr),
    .wgray_o       (wgray),
    .full_o        (full_o),
    .almost_full_o (almost_full_o),
    .wr_level_o    (wr_level_o),
    .wr_overflow_o (wr_overflow_o)
  );

  cdckit_sync #(
    .WIDTH      (PTR_W),
    .NUM_STAGES (NUM_STAGES)
  ) u_sync_r2w (          // [FUNC-1]
    .clk_i  (wclk_i),
    .rst_ni (wrst_ni),    // [MAS-AF-10]
    .d_i    (rgray),      // [MAS-AF-2]
    .q_o    (wq2_rgray)
  );

  // ---------------------------------------------------------------------------
  // Memory
  // ---------------------------------------------------------------------------
  cdckit_afifo_mem #(
    .DATA_W (DATA_W),
    .DEPTH  (DEPTH)
  ) u_mem (               // [MAS-AF-7]
    .wclk_i  (wclk_i),
    .we_i    (mem_we),
    .waddr_i (waddr),
    .wdata_i (wr_data_i),
    .raddr_i (raddr),
    .rdata_o (mem_rdata)
  );

  // ---------------------------------------------------------------------------
  // Read domain
  // ---------------------------------------------------------------------------
  cdckit_afifo_rptr #(
    .DEPTH     (DEPTH),
    .AE_THRESH (AE_THRESH)
  ) u_rptr (
    .rclk_i         (rclk_i),
    .rrst_ni        (rrst_ni),
    .rd_en_i        (rd_en_i),
    .rq2_wgray_i    (rq2_wgray),
    .raddr_o        (raddr),
    .rgray_o        (rgray),
    .empty_o        (empty_o),
    .almost_empty_o (almost_empty_o),
    .rd_level_o     (rd_level_o),
    .rd_underflow_o (rd_underflow_o)
  );

  cdckit_sync #(
    .WIDTH      (PTR_W),
    .NUM_STAGES (NUM_STAGES)
  ) u_sync_w2r (          // [FUNC-1]
    .clk_i  (rclk_i),
    .rst_ni (rrst_ni),    // [MAS-AF-10]
    .d_i    (wgray),      // [MAS-AF-2]
    .q_o    (rq2_wgray)
  );

  // With OUTPUT_ZERO_IF_EMPTY the output is qualified by empty_o: a consumer that does
  // not look at empty_o never observes the CDC-X09 path [AI Feedback].
  if (OUTPUT_ZERO_IF_EMPTY) begin : g_zero_if_empty
    assign rd_data_o = empty_o ? '0 : mem_rdata; // [FUNC-10] [FUNC-11]
  end else begin : g_raw_rdata
    assign rd_data_o = mem_rdata; // [FUNC-10]
  end

endmodule : cdckit_afifo
