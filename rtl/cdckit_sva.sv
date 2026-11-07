// -----------------------------------------------------------------------------
// cdckit_sva.sv
// CDCKIT design assertions
// -----------------------------------------------------------------------------
`ifndef SYNTHESIS

// =============================================================================
// cdckit_afifo_wptr
// =============================================================================
module cdckit_afifo_wptr_sva #(
  parameter int unsigned DEPTH     = 32,
  parameter int unsigned AW        = 5,
  parameter int unsigned AF_THRESH = DEPTH - 4
) (
  input logic        wclk_i,
  input logic        wrst_ni,
  input logic        wr_en_i,
  input logic        full_q,
  input logic        almost_full_q,
  input logic [AW:0] wbin_q,
  input logic [AW:0] wgray_q,
  input logic [AW:0] wr_level_q
);

  // [MAS-AF-2]
  a_wgray_onebit: assert property (@(posedge wclk_i) disable iff (!wrst_ni) $countones(wgray_q ^ $past(wgray_q)) <= 1)
    else $error("SVA-01: wgray_q changed more than one bit");

  // [FUNC-8]
  a_wr_full_hold: assert property (@(posedge wclk_i) disable iff (!wrst_ni) wr_en_i && full_q |=> $stable(wbin_q))
    else $error("SVA-03: write accepted with full_q = 1");

  // [FUNC-9]
  a_wlevel_max:   assert property (@(posedge wclk_i) disable iff (!wrst_ni) wr_level_q <= (AW+1)'(DEPTH))
    else $error("SVA-05: wr_level_q = %0d > DEPTH", wr_level_q);

  // [FUNC-12]
  a_full_known:   assert property (@(posedge wclk_i) disable iff (!wrst_ni) !$isunknown(full_q))
    else $error("SVA-07: full_q is unknown");

  // [FUNC-15]
  a_full_level:   assert property (@(posedge wclk_i) disable iff (!wrst_ni) full_q == (wr_level_q == (AW+1)'(DEPTH)))
    else $error("SVA-14: full_q inconsistent with wr_level_q = %0d", wr_level_q);

  // [FUNC-15]
  a_afull_level:  assert property (@(posedge wclk_i) disable iff (!wrst_ni) almost_full_q == (wr_level_q >= (AW+1)'(AF_THRESH)))
    else $error("SVA-15: almost_full_q inconsistent with wr_level_q = %0d", wr_level_q);
endmodule : cdckit_afifo_wptr_sva

// =============================================================================
// cdckit_afifo_rptr
// =============================================================================
module cdckit_afifo_rptr_sva #(
  parameter int unsigned DEPTH     = 32,
  parameter int unsigned AW        = 5,
  parameter int unsigned AE_THRESH = 2
) (
  input logic        rclk_i,
  input logic        rrst_ni,
  input logic        rd_en_i,
  input logic        empty_q,
  input logic        almost_empty_q,
  input logic [AW:0] rbin_q,
  input logic [AW:0] rgray_q,
  input logic [AW:0] rd_level_q
);

  // [MAS-AF-2]
  a_rgray_onebit: assert property (@(posedge rclk_i) disable iff (!rrst_ni) $countones(rgray_q ^ $past(rgray_q)) <= 1)
    else $error("SVA-02: rgray_q changed more than one bit");

  // [FUNC-8]
  a_rd_empty_hold: assert property (@(posedge rclk_i) disable iff (!rrst_ni) rd_en_i && empty_q |=> $stable(rbin_q))
    else $error("SVA-04: read accepted with empty_q = 1");

  // [FUNC-9]
  a_rlevel_max:   assert property (@(posedge rclk_i) disable iff (!rrst_ni) rd_level_q <= (AW+1)'(DEPTH))
    else $error("SVA-06: rd_level_q = %0d > DEPTH", rd_level_q);

  // [FUNC-12]
  a_empty_known:  assert property (@(posedge rclk_i) disable iff (!rrst_ni) !$isunknown(empty_q))
    else $error("SVA-07: empty_q is unknown");

  // [FUNC-15]
  a_empty_level:  assert property (@(posedge rclk_i) disable iff (!rrst_ni) empty_q == (rd_level_q == '0))
    else $error("SVA-16: empty_q inconsistent with rd_level_q = %0d", rd_level_q);

  // [FUNC-15]
  a_aempty_level: assert property (@(posedge rclk_i) disable iff (!rrst_ni) almost_empty_q == (rd_level_q <= (AW+1)'(AE_THRESH)))
    else $error("SVA-17: almost_empty_q inconsistent with rd_level_q = %0d", rd_level_q);
endmodule : cdckit_afifo_rptr_sva

// =============================================================================
// cdckit_hs
// =============================================================================
module cdckit_hs_sva #(
  parameter int unsigned DATA_W = 32
) (
  input logic              clk_src_i,
  input logic              rst_src_ni,
  input logic              src_valid_i,
  input logic              src_ready_o,
  input logic [DATA_W-1:0] src_data_i,
  input logic [DATA_W-1:0] hold_q,
  input logic [2:0]        current_state,
  input logic              ack_s,
  input logic              clk_dst_i,
  input logic              rst_dst_ni,
  input logic              dst_valid_q
);
  // [MAS-HS-6]
  a_state_onehot: assert property (
    @(posedge clk_src_i) disable iff (!rst_src_ni)
    $onehot(current_state)
  ) else $error("SVA-08: illegal state in the source FSM");

  // [MAS-HS-2]
  a_hold_stable: assert property (
    @(posedge clk_src_i) disable iff (!rst_src_ni)
    !src_ready_o |=> $stable(hold_q)
  ) else $error("SVA-09: hold_q changed during the transfer");

  // [FUNC-16]
  a_dst_pulse: assert property (
    @(posedge clk_dst_i) disable iff (!rst_dst_ni)
    dst_valid_q |=> !dst_valid_q
  ) else $error("SVA-10: dst_valid_o active for more than one cycle");

  // SVA-11 (environment assumption): sender valid/ready contract
  m_src_stable: assert property (
    @(posedge clk_src_i) disable iff (!rst_src_ni)
    src_valid_i && !src_ready_o |=> src_valid_i && $stable(src_data_i)
  ) else $error("SVA-11: sender dropped valid or changed data while src_ready_o = 0");

  // [FUNC-6] [MAS-HS-7]
  a_ready_no_ack: assert property (
    @(posedge clk_src_i) disable iff (!rst_src_ni)
    src_ready_o |-> !ack_s
  ) else $error("SVA-18: src_ready_o = 1 while ack_s = 1");
endmodule : cdckit_hs_sva

// =============================================================================
// cdckit_pulse_sync
// MIN_GAP: minimum spacing in source cycles derived from [PERF-3] for the clock ratio
// of the environment. [AI Feedback]
// =============================================================================
module cdckit_pulse_sync_sva #(
  parameter int unsigned MIN_GAP = 8
) (
  input logic clk_src_i,
  input logic rst_src_ni,
  input logic pulse_src_i,
  input logic clk_dst_i,
  input logic rst_dst_ni,
  input logic pulse_dst_q
);
  if (MIN_GAP < 2) begin : g_err_gap
    $fatal(1, "cdckit_pulse_sync_sva: MIN_GAP must be >= 2");
  end

  // [PERF-3]
  m_min_gap: assert property (
    @(posedge clk_src_i) disable iff (!rst_src_ni)
    pulse_src_i |=> !pulse_src_i [*MIN_GAP-1]
  ) else $error("SVA-12: source pulses closer than MIN_GAP = %0d", MIN_GAP);

  // [FUNC-4]
  a_dst_pulse: assert property (
    @(posedge clk_dst_i) disable iff (!rst_dst_ni)
    pulse_dst_q |=> !pulse_dst_q
  ) else $error("SVA-13: pulse_dst_o active for more than one cycle");
endmodule : cdckit_pulse_sync_sva

`endif // SYNTHESIS
