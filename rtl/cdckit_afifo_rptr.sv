// -----------------------------------------------------------------------------
// cdckit_afifo_rptr.sv
// Read pointer logic of the asynchronous FIFO 
// -----------------------------------------------------------------------------
module cdckit_afifo_rptr
  import cdckit_pkg::*;
#(
  parameter int unsigned  DEPTH     = 32,
  parameter int unsigned  AE_THRESH = 2,
  localparam int unsigned AW        = unsigned'($clog2(DEPTH)),
  localparam int unsigned PTR_W     = AW + 1
) (
  input  logic             rclk_i,
  input  logic             rrst_ni,
  input  logic             rd_en_i,
  input  logic [PTR_W-1:0] rq2_wgray_i,     // write pointer (Gray) synchronized to rclk
  output logic [AW-1:0]    raddr_o,
  output logic [PTR_W-1:0] rgray_o,         // registered Gray pointer towards the write domain
  output logic             empty_o,
  output logic             almost_empty_o,
  output logic [PTR_W-1:0] rd_level_o,
  output logic             rd_underflow_o
);

  logic [PTR_W-1:0] rbin_q, rbin_d;
  logic [PTR_W-1:0] rgray_d;
  // Without DONT_TOUCH, Vivado merges
  // both registers and the flop that launches crossing gets renamed [AI Feedback]
  (* DONT_TOUCH = "TRUE" *)
  logic [PTR_W-1:0] rgray_q;
  logic [PTR_W-1:0] rq2_wbin;
  logic [PTR_W-1:0] rlevel_d;
  logic [PTR_W-1:0] rd_level_q;
  logic             r_pop;
  logic             empty_q, empty_d;
  logic             almost_empty_q;
  logic             rd_underflow_q;

  assign r_pop   = rd_en_i & ~empty_q;
  assign rbin_d  = rbin_q + PTR_W'(r_pop);
  assign rgray_d = PTR_W'(bin2gray(PTR_MAX_W'(rbin_d)));

  // Empty = identical pointers, including the lap bit.
  assign empty_d = (rgray_d == rq2_wgray_i);

  assign rq2_wbin = PTR_W'(gray2bin(PTR_MAX_W'(rq2_wgray_i)));
  assign rlevel_d = rq2_wbin - rbin_d;

  always_ff @(posedge rclk_i or negedge rrst_ni) begin
    if (!rrst_ni) begin
      rbin_q         <= '0;
      rgray_q        <= '0;
      empty_q        <= 1'b1;
      almost_empty_q <= 1'b1;
      rd_level_q     <= '0;
      rd_underflow_q <= 1'b0;
    end else begin
      rbin_q         <= rbin_d;
      rgray_q        <= rgray_d;
      empty_q        <= empty_d;
      almost_empty_q <= (rlevel_d <= PTR_W'(AE_THRESH));
      rd_level_q     <= rlevel_d;
      rd_underflow_q <= rd_en_i & empty_q;
    end
  end

  assign raddr_o        = rbin_q[AW-1:0];
  assign rgray_o        = rgray_q;
  assign empty_o        = empty_q;
  assign almost_empty_o = almost_empty_q;
  assign rd_level_o     = rd_level_q;
  assign rd_underflow_o = rd_underflow_q;

endmodule : cdckit_afifo_rptr
