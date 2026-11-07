// -----------------------------------------------------------------------------
// cdckit_smoke_tb.sv
// Directed smoke test of every primitive and of the implementation harness.
// Stimulus and sampling happen on falling edges, so there are no races with the
// rising-edge logic of the DUTs.
// -----------------------------------------------------------------------------
`timescale 1ps/1ps

module cdckit_smoke_tb;

  localparam int unsigned DATA_W  = 72;
  localparam int unsigned DEPTH   = 32;
  localparam int unsigned PTR_W   = $clog2(DEPTH) + 1;
  localparam int unsigned HS_W    = 64;
  localparam int unsigned STREAM  = 300;
  localparam int unsigned HS_N    = 16;
  localparam int unsigned PULSE_N = 16;
  localparam int unsigned GAP     = 8;  // [PERF-3]

  logic wclk = 1'b0;
  logic rclk = 1'b0;
  logic arst_n = 1'b0;
  logic wrst_n, rrst_n;

  always #3200 wclk = ~wclk;
  initial begin
    #700;
    forever #2000 rclk = ~rclk;
  end

  int errors = 0;

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $error("%s", msg);
    end
  endtask

  function automatic logic [DATA_W-1:0] fifo_word(input int unsigned i);
    return 72'hA5_0F0F_3C3C_5A5A_0000 ^ DATA_W'(i);
  endfunction

  function automatic logic [HS_W-1:0] hs_word(input int unsigned i);
    return 64'hDEAD_BEEF_0000_0000 ^ HS_W'(i * 32'h0101_0101);
  endfunction

  // ---------------------------------------------------------------------------
  // DUTs
  // ---------------------------------------------------------------------------
  cdckit_rst_sync u_rst_w (.clk_i(wclk), .arst_ni(arst_n), .rst_no(wrst_n));
  cdckit_rst_sync u_rst_r (.clk_i(rclk), .arst_ni(arst_n), .rst_no(rrst_n));

  logic              wr_en = 1'b0;
  logic [DATA_W-1:0] wr_data = '0;
  logic              full, almost_full, wr_overflow;
  logic [PTR_W-1:0]  wr_level;
  logic              rd_en = 1'b0;
  logic [DATA_W-1:0] rd_data;
  logic              empty, almost_empty, rd_underflow;
  logic [PTR_W-1:0]  rd_level;

  cdckit_afifo #(.DATA_W(DATA_W), .DEPTH(DEPTH)) u_afifo (
    .wclk_i         (wclk),
    .wrst_ni        (wrst_n),
    .wr_en_i        (wr_en),
    .wr_data_i      (wr_data),
    .full_o         (full),
    .almost_full_o  (almost_full),
    .wr_level_o     (wr_level),
    .wr_overflow_o  (wr_overflow),
    .rclk_i         (rclk),
    .rrst_ni        (rrst_n),
    .rd_en_i        (rd_en),
    .rd_data_o      (rd_data),
    .empty_o        (empty),
    .almost_empty_o (almost_empty),
    .rd_level_o     (rd_level),
    .rd_underflow_o (rd_underflow)
  );

  logic            src_valid = 1'b0;
  logic            src_ready;
  logic [HS_W-1:0] src_data = '0;
  logic            dst_valid;
  logic [HS_W-1:0] dst_data;

  cdckit_hs #(.DATA_W(HS_W)) u_hs (
    .clk_src_i   (wclk),
    .rst_src_ni  (wrst_n),
    .src_valid_i (src_valid),
    .src_ready_o (src_ready),
    .src_data_i  (src_data),
    .clk_dst_i   (rclk),
    .rst_dst_ni  (rrst_n),
    .dst_valid_o (dst_valid),
    .dst_data_o  (dst_data)
  );

  logic pulse_src = 1'b0;
  logic pulse_dst;

  cdckit_pulse_sync u_pulse (
    .clk_src_i   (wclk),
    .rst_src_ni  (wrst_n),
    .pulse_src_i (pulse_src),
    .clk_dst_i   (rclk),
    .rst_dst_ni  (rrst_n),
    .pulse_dst_o (pulse_dst)
  );

  logic w_obs, r_obs, top_err;

  cdckit_impl_top u_top (
    .wclk_i  (wclk),
    .rclk_i  (rclk),
    .arst_ni (arst_n),
    .w_obs_o (w_obs),
    .r_obs_o (r_obs),
    .err_o   (top_err)
  );

  // ---------------------------------------------------------------------------
  // Destination monitors
  // ---------------------------------------------------------------------------
  int unsigned hs_rx    = 0;
  int unsigned pulse_rx = 0;

  always @(negedge rclk) begin
    if (rrst_n === 1'b1 && dst_valid === 1'b1) begin
      check(dst_data === hs_word(hs_rx), "cdckit_hs: wrong word delivered"); // [FUNC-5]
      hs_rx++;
    end
    if (rrst_n === 1'b1 && pulse_dst === 1'b1) begin
      pulse_rx++;
    end
  end

  // ---------------------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------------------
  task automatic test_reset();
    #1000;
    check(wrst_n === 1'b0 && rrst_n === 1'b0, "reset not asserted"); // [FUNC-3]
    repeat (8) @(negedge wclk);
    arst_n = 1'b1;
    repeat (3) @(posedge wclk);
    #100;
    check(wrst_n === 1'b1, "wclk reset not released in N+1 edges"); // [FUNC-3]
    repeat (3) @(posedge rclk);
    #100;
    check(rrst_n === 1'b1, "rclk reset not released in N+1 edges"); // [FUNC-3]
    repeat (2) @(negedge wclk);
    check(empty === 1'b1 && almost_empty === 1'b1, "FIFO not empty after reset"); // [FUNC-12]
    check(full === 1'b0 && almost_full === 1'b0, "FIFO full after reset");        // [FUNC-12]
    check(wr_level == 0 && rd_level == 0, "levels not zero after reset");         // [FUNC-12]
  endtask

  task automatic test_fifo_fill_drain();
    for (int unsigned i = 0; i < DEPTH; i++) begin
      @(negedge wclk);
      check(full === 1'b0, "full_o asserted before DEPTH words");
      wr_en   = 1'b1;
      wr_data = fifo_word(i);
    end
    @(negedge wclk);
    wr_en = 1'b0;
    check(full === 1'b1, "full_o not asserted after DEPTH words"); // [FUNC-9]
    check(almost_full === 1'b1 && wr_level == DEPTH, "wrong write-side status"); // [FUNC-15]

    // Rejected write
    wr_en = 1'b1;
    @(negedge wclk);
    wr_en = 1'b0;
    check(wr_overflow === 1'b1, "wr_overflow_o not asserted"); // [FUNC-8]
    @(negedge wclk);
    check(wr_overflow === 1'b0, "wr_overflow_o wider than one cycle"); // [FUNC-8]

    repeat (10) @(negedge rclk);
    check(empty === 1'b0 && rd_level == DEPTH, "wrong read-side status"); // [PERF-8]

    for (int unsigned i = 0; i < DEPTH; i++) begin
      @(negedge rclk);
      check(empty === 1'b0, "empty_o asserted with words stored");
      check(rd_data === fifo_word(i), "FIFO word out of order"); // [FUNC-7] [FUNC-10]
      rd_en = 1'b1;
    end
    @(negedge rclk);
    check(empty === 1'b1, "empty_o not asserted after draining"); // [FUNC-9]

    // Rejected read: rd_en_i is still high with the FIFO empty
    @(negedge rclk);
    rd_en = 1'b0;
    check(rd_underflow === 1'b1, "rd_underflow_o not asserted"); // [FUNC-8]

    repeat (10) @(negedge wclk);
    check(full === 1'b0 && wr_level == 0, "write side did not see the drain"); // [PERF-8]
  endtask

  task automatic test_fifo_stream();
    fork
      begin : writer
        int unsigned n = 0;
        while (n < STREAM) begin
          @(negedge wclk);
          if (!full && $urandom_range(3) != 0) begin
            wr_en   = 1'b1;
            wr_data = fifo_word(n);
            n++;
          end else begin
            wr_en = 1'b0;
          end
        end
        @(negedge wclk);
        wr_en = 1'b0;
      end
      begin : reader
        int unsigned m = 0;
        while (m < STREAM) begin
          @(negedge rclk);
          if (!empty && $urandom_range(3) != 0) begin
            rd_en = 1'b1;
            check(rd_data === fifo_word(m), "FIFO stream word mismatch"); // [FUNC-7]
            m++;
          end else begin
            rd_en = 1'b0;
          end
        end
        @(negedge rclk);
        rd_en = 1'b0;
      end
    join
  endtask

  task automatic test_hs();
    for (int unsigned i = 0; i < HS_N; i++) begin
      @(negedge wclk);
      src_valid = 1'b1;
      src_data  = hs_word(i);
      while (src_ready !== 1'b1) @(negedge wclk);
      @(negedge wclk);
      src_valid = 1'b0;
    end
    repeat (40) @(negedge rclk);
    check(hs_rx == HS_N, "cdckit_hs: word count mismatch"); // [FUNC-5]
  endtask

  task automatic test_pulse();
    for (int unsigned i = 0; i < PULSE_N; i++) begin
      @(negedge wclk);
      pulse_src = 1'b1;
      @(negedge wclk);
      pulse_src = 1'b0;
      repeat (GAP) @(negedge wclk);
    end
    repeat (10) @(negedge rclk);
    check(pulse_rx == PULSE_N, "cdckit_pulse_sync: event count mismatch"); // [FUNC-4]
  endtask

  task automatic test_harness();
    repeat (5000) @(negedge rclk);
    check(top_err === 1'b0, "harness err_o asserted");
    check(u_top.r_lfsr_q != u_top.DATA_SEED, "harness FIFO traffic did not run");
    check(u_top.hs_ref_q != u_top.HS_SEED, "harness handshake traffic did not run");
    check(u_top.pls_cnt_q != '0, "harness pulse traffic did not run");
  endtask

  initial begin
    test_reset();
    test_fifo_fill_drain();
    test_fifo_stream();
    test_hs();
    test_pulse();
    test_harness();
    if (errors == 0) begin
      $display("SMOKE TEST PASSED");
    end else begin
      $display("SMOKE TEST FAILED: %0d errors", errors);
    end
    $finish;
  end

  initial begin
    #100_000_000;
    $fatal(1, "SMOKE TEST TIMEOUT");
  end

endmodule : cdckit_smoke_tb
