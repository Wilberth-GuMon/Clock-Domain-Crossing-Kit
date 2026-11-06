// -----------------------------------------------------------------------------
// cdckit_impl_top.sv
// Implementation harness: LFSR traffic through cdckit_afifo and cdckit_hs,
// and paced events through cdckit_pulse_sync
// -----------------------------------------------------------------------------
module cdckit_impl_top (
  input  logic wclk_i,  // [MAS-XDC-5]
  input  logic rclk_i,  // [MAS-XDC-5]
  input  logic arst_ni,
  output logic w_obs_o, // [MAS-XDC-6]
  output logic r_obs_o, // [MAS-XDC-6]
  output logic err_o    // [MAS-XDC-6]
);

  localparam int unsigned   DATA_W     = 72;
  localparam int unsigned   DEPTH      = 32;
  localparam int unsigned   NUM_STAGES = 2;
  localparam int unsigned   PTR_W      = unsigned'($clog2(DEPTH)) + 1;

  localparam logic [71:0]   DATA_SEED  = 72'h5A_C3F0_0FF0_A55A_1234;
  localparam logic [15:0]   W_GATE_SEED = 16'hACE1;
  localparam logic [15:0]   R_GATE_SEED = 16'h1D0B;

  // x^72 + x^66 + x^25 + x^19 + 1
  function automatic logic [71:0] next_data(input logic [71:0] s);
    return {s[70:0], s[71] ^ s[65] ^ s[24] ^ s[18]};
  endfunction

  // x^16 + x^15 + x^13 + x^4 + 1
  function automatic logic [15:0] next_gate(input logic [15:0] s);
    return {s[14:0], s[15] ^ s[14] ^ s[12] ^ s[3]};
  endfunction

  logic wrst_n, rrst_n;

  cdckit_rst_sync #(.NUM_STAGES(NUM_STAGES)) u_rst_w ( // [RST-3]
    .clk_i   (wclk_i),
    .arst_ni (arst_ni),
    .rst_no  (wrst_n)
  );

  cdckit_rst_sync #(.NUM_STAGES(NUM_STAGES)) u_rst_r ( // [RST-3]
    .clk_i   (rclk_i),
    .arst_ni (arst_ni),
    .rst_no  (rrst_n)
  );

  // IP ports
  logic              full, almost_full, wr_overflow;
  logic              empty, almost_empty, rd_underflow;
  logic [PTR_W-1:0]  wr_level, rd_level;
  logic [DATA_W-1:0] rd_data;

  // ---------------------------------------------------------------------------
  // Write domain: generator
  // Gating on the registered almost_full keeps every issued write accepted.
  // ---------------------------------------------------------------------------
  logic [15:0]       w_gate_q;
  logic [71:0]       w_lfsr_q;
  logic              wr_en_q;
  logic [DATA_W-1:0] wr_data_q;
  logic              full_q, almost_full_q, wr_overflow_q;
  logic [PTR_W-1:0]  wr_level_q;
  logic              w_obs_q;
  logic              w_go;

  assign w_go = (|w_gate_q[1:0]) & ~almost_full_q;

  always_ff @(posedge wclk_i or negedge wrst_n) begin
    if (!wrst_n) begin
      w_gate_q      <= W_GATE_SEED;
      w_lfsr_q      <= DATA_SEED;
      wr_en_q       <= 1'b0;
      wr_data_q     <= '0;
      full_q        <= 1'b0;
      almost_full_q <= 1'b0;
      wr_overflow_q <= 1'b0;
      wr_level_q    <= '0;
      w_obs_q       <= 1'b0;
    end else begin
      w_gate_q      <= next_gate(w_gate_q);
      wr_en_q       <= w_go;
      wr_data_q     <= w_lfsr_q;
      if (w_go) begin
        w_lfsr_q    <= next_data(w_lfsr_q);
      end
      full_q        <= full;
      almost_full_q <= almost_full;
      wr_overflow_q <= wr_overflow;
      wr_level_q    <= wr_level;
      w_obs_q       <= ^{full_q, wr_overflow_q, wr_level_q};
    end
  end

  // ---------------------------------------------------------------------------
  // FIFO under test
  // ---------------------------------------------------------------------------
  logic rd_en_q;

  cdckit_afifo #(
    .DATA_W     (DATA_W),
    .DEPTH      (DEPTH),
    .NUM_STAGES (NUM_STAGES)
  ) u_afifo (
    .wclk_i         (wclk_i),
    .wrst_ni        (wrst_n),
    .wr_en_i        (wr_en_q),      // [INTG-12]
    .wr_data_i      (wr_data_q),
    .full_o         (full),
    .almost_full_o  (almost_full),
    .wr_level_o     (wr_level),
    .wr_overflow_o  (wr_overflow),
    .rclk_i         (rclk_i),
    .rrst_ni        (rrst_n),
    .rd_en_i        (rd_en_q),      // [INTG-12]
    .rd_data_o      (rd_data),
    .empty_o        (empty),
    .almost_empty_o (almost_empty),
    .rd_level_o     (rd_level),
    .rd_underflow_o (rd_underflow)
  );

  // ---------------------------------------------------------------------------
  // cdckit_hs: words from wclk to rclk
  // ---------------------------------------------------------------------------
  localparam int unsigned HS_W    = 64;
  localparam logic [63:0] HS_SEED = 64'hC0DE_F00D_1234_ABCD;

  // x^64 + x^63 + x^61 + x^60 + 1
  function automatic logic [63:0] next_hs(input logic [63:0] s);
    return {s[62:0], s[63] ^ s[62] ^ s[60] ^ s[59]};
  endfunction

  logic            hs_valid_q;
  logic            hs_ready;
  logic [HS_W-1:0] hs_src_q;
  logic            hs_dst_valid;
  logic [HS_W-1:0] hs_dst_data;
  logic            hs_dv_q;
  logic [HS_W-1:0] hs_dd_q;
  logic [HS_W-1:0] hs_ref_q;
  logic            hs_mismatch_q;

  always_ff @(posedge wclk_i or negedge wrst_n) begin
    if (!wrst_n) begin
      hs_valid_q <= 1'b0;
      hs_src_q   <= HS_SEED;
    end else begin
      hs_valid_q <= 1'b1;
      if (hs_valid_q && hs_ready) begin
        hs_src_q <= next_hs(hs_src_q);
      end
    end
  end

  cdckit_hs #(
    .DATA_W     (HS_W),
    .NUM_STAGES (NUM_STAGES)
  ) u_hs (
    .clk_src_i   (wclk_i),
    .rst_src_ni  (wrst_n),
    .src_valid_i (hs_valid_q),   // [INTG-12]
    .src_ready_o (hs_ready),
    .src_data_i  (hs_src_q),
    .clk_dst_i   (rclk_i),
    .rst_dst_ni  (rrst_n),
    .dst_valid_o (hs_dst_valid), // [INTG-11]
    .dst_data_o  (hs_dst_data)
  );

  always_ff @(posedge rclk_i or negedge rrst_n) begin
    if (!rrst_n) begin
      hs_dv_q       <= 1'b0;
      hs_dd_q       <= '0;
      hs_ref_q      <= HS_SEED;
      hs_mismatch_q <= 1'b0;
    end else begin
      hs_dv_q       <= hs_dst_valid;
      hs_dd_q       <= hs_dst_data;
      if (hs_dv_q) begin
        hs_ref_q    <= next_hs(hs_ref_q);
      end
      hs_mismatch_q <= hs_dv_q & (hs_dd_q != hs_ref_q);
    end
  end

  // ---------------------------------------------------------------------------
  // cdckit_pulse_sync: events from wclk to rclk, spaced >= 8 wclk cycles
  // ---------------------------------------------------------------------------
  logic [2:0] pls_gap_q;
  logic       pls_src_q;
  logic       pls_dst;
  logic       pls_dst_q;
  logic [7:0] pls_cnt_q;

  always_ff @(posedge wclk_i or negedge wrst_n) begin
    if (!wrst_n) begin
      pls_gap_q <= '0;
      pls_src_q <= 1'b0;
    end else begin
      pls_gap_q <= pls_gap_q + 3'd1;
      pls_src_q <= (&pls_gap_q) & w_gate_q[2]; // [PERF-3]
    end
  end

  cdckit_pulse_sync #(
    .NUM_STAGES (NUM_STAGES)
  ) u_pulse (
    .clk_src_i   (wclk_i),
    .rst_src_ni  (wrst_n),
    .pulse_src_i (pls_src_q),
    .clk_dst_i   (rclk_i),
    .rst_dst_ni  (rrst_n),
    .pulse_dst_o (pls_dst)
  );

  always_ff @(posedge rclk_i or negedge rrst_n) begin
    if (!rrst_n) begin
      pls_dst_q <= 1'b0;
      pls_cnt_q <= '0;
    end else begin
      pls_dst_q <= pls_dst;
      if (pls_dst_q) begin
        pls_cnt_q <= pls_cnt_q + 8'd1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Read domain: checker
  // Gating on the registered almost_empty keeps every issued read accepted.
  // ---------------------------------------------------------------------------
  logic [15:0]       r_gate_q;
  logic [71:0]       r_lfsr_q;
  logic              rd_pop_q;
  logic [DATA_W-1:0] rd_data_q;
  logic              empty_q, almost_empty_q, rd_underflow_q;
  logic [PTR_W-1:0]  rd_level_q;
  logic              mismatch_q;
  logic              err_q;
  logic              r_obs_q;
  logic              r_go;

  assign r_go = r_gate_q[0] & ~almost_empty_q;

  always_ff @(posedge rclk_i or negedge rrst_n) begin
    if (!rrst_n) begin
      r_gate_q       <= R_GATE_SEED;
      r_lfsr_q       <= DATA_SEED;
      rd_en_q        <= 1'b0;
      rd_pop_q       <= 1'b0;
      rd_data_q      <= '0;
      empty_q        <= 1'b1;
      almost_empty_q <= 1'b1;
      rd_underflow_q <= 1'b0;
      rd_level_q     <= '0;
      mismatch_q     <= 1'b0;
      err_q          <= 1'b0;
      r_obs_q        <= 1'b0;
    end else begin
      r_gate_q       <= next_gate(r_gate_q);
      rd_en_q        <= r_go;
      rd_pop_q       <= rd_en_q;
      rd_data_q      <= rd_data;    // [INTG-6]
      if (rd_pop_q) begin
        r_lfsr_q     <= next_data(r_lfsr_q);
      end
      empty_q        <= empty;
      almost_empty_q <= almost_empty;
      rd_underflow_q <= rd_underflow;
      rd_level_q     <= rd_level;
      mismatch_q     <= rd_pop_q & (rd_data_q != r_lfsr_q);
      err_q          <= err_q | mismatch_q | rd_underflow_q | hs_mismatch_q;
      r_obs_q        <= ^{empty_q, rd_level_q, pls_cnt_q};
    end
  end

  assign w_obs_o = w_obs_q;
  assign r_obs_o = r_obs_q;
  assign err_o   = err_q;

endmodule : cdckit_impl_top
