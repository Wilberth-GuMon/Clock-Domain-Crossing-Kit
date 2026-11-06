// -----------------------------------------------------------------------------
// cdckit_afifo_wptr.sv
// Write pointer logic of the asynchronous FIFO
// -----------------------------------------------------------------------------
module cdckit_afifo_wptr
  import cdckit_pkg::*;
#(
  parameter int unsigned  DEPTH     = 32,
  parameter int unsigned  AF_THRESH = DEPTH - 4,
  localparam int unsigned AW        = unsigned'($clog2(DEPTH)),
  localparam int unsigned PTR_W     = AW + 1 // [MAS-AF-1]
) (
  input  logic             wclk_i,
  input  logic             wrst_ni,
  input  logic             wr_en_i,
  input  logic [PTR_W-1:0] wq2_rgray_i,     // read pointer (Gray) synchronized to wclk
  output logic             mem_we_o,
  output logic [AW-1:0]    waddr_o,
  output logic [PTR_W-1:0] wgray_o,         // registered Gray pointer towards the read domain
  output logic             full_o,
  output logic             almost_full_o,
  output logic [PTR_W-1:0] wr_level_o,
  output logic             wr_overflow_o
);

  logic [PTR_W-1:0] wbin_q, wbin_d; // [MAS-AF-3]
  logic [PTR_W-1:0] wgray_d;
  // wgray_q[AW] is identical to wbin_q[AW]. Without DONT_TOUCH, Vivado merges
  // both registers and the flop that launches crossing gets renamed [AI Feedback]
  (* DONT_TOUCH = "TRUE" *) // [MAS-AF-9]
  logic [PTR_W-1:0] wgray_q; // [MAS-AF-3]
  logic [PTR_W-1:0] wq2_rbin;
  logic [PTR_W-1:0] wlevel_d;
  logic [PTR_W-1:0] wr_level_q;
  logic             w_push;
  logic             full_q, full_d;
  logic             almost_full_q;
  logic             wr_overflow_q;

  assign w_push  = wr_en_i & ~full_q; // [FUNC-8]
  assign wbin_d  = wbin_q + PTR_W'(w_push);
  assign wgray_d = PTR_W'(bin2gray(PTR_MAX_W'(wbin_d)));

  // Full = same memory position with a one-lap lead. In reflected Gray code this is
  // equivalent to the two MSBs inverted and the rest equal. It is evaluated with the
  // next pointer so the flag reflects this cycle's write without an extra cycle [AI Feedback].
  assign full_d = (wgray_d == {~wq2_rgray_i[AW:AW-1], wq2_rgray_i[AW-2:0]}); // [MAS-AF-4] [MAS-AF-5]

  // Occupancy seen from the write side: an upper bound of the real one, because the
  // read pointer arrives late through the synchronizer [AI Feedback].
  assign wq2_rbin = PTR_W'(gray2bin(PTR_MAX_W'(wq2_rgray_i))); // [MAS-AF-8]
  assign wlevel_d = wbin_d - wq2_rbin; // [FUNC-9] [MAS-AF-6]

  always_ff @(posedge wclk_i or negedge wrst_ni) begin // [RST-1]
    if (!wrst_ni) begin // [FUNC-12]
      wbin_q        <= '0;
      wgray_q       <= '0;
      full_q        <= 1'b0;
      almost_full_q <= 1'b0;
      wr_level_q    <= '0;
      wr_overflow_q <= 1'b0;
    end else begin
      wbin_q        <= wbin_d;
      wgray_q       <= wgray_d;
      full_q        <= full_d;                            // [FUNC-15]
      almost_full_q <= (wlevel_d >= PTR_W'(AF_THRESH));   // [FUNC-15]
      wr_level_q    <= wlevel_d;
      wr_overflow_q <= wr_en_i & full_q;                  // [FUNC-8]
    end
  end

  assign mem_we_o      = w_push;
  assign waddr_o       = wbin_q[AW-1:0]; // [MAS-AF-3]
  assign wgray_o       = wgray_q;      // registered: wgray_d is never synchronized // [MAS-AF-2]
  assign full_o        = full_q;        // [FUNC-13]
  assign almost_full_o = almost_full_q; // [FUNC-13]
  assign wr_level_o    = wr_level_q;    // [FUNC-13]
  assign wr_overflow_o = wr_overflow_q; // [FUNC-13]

endmodule : cdckit_afifo_wptr
