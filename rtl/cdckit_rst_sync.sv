// -----------------------------------------------------------------------------
// cdckit_rst_sync
// Reset synchronizer: asynchronous assertion, synchronous release
// -----------------------------------------------------------------------------
module cdckit_rst_sync #(
  parameter int unsigned NUM_STAGES = 2
) (
  input  logic clk_i,
  input  logic arst_ni,
  output logic rst_no
);

  // arst_ni (immediate assertion, no clock needed); the reset deasserts after NUM_STAGES edges.
  cdckit_sync #(
    .WIDTH      (1),
    .NUM_STAGES (NUM_STAGES),
    .RESET_VAL  (1'b0)
  ) u_sync (
    .clk_i  (clk_i),
    .rst_ni (arst_ni),
    .d_i    (1'b1),
    .q_o    (rst_no)
  );

endmodule : cdckit_rst_sync
