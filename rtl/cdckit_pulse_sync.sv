// -----------------------------------------------------------------------------
// cdckit_pulse_sync
// Toggle-based pulse synchronizer
// -----------------------------------------------------------------------------
module cdckit_pulse_sync #(
  parameter int unsigned NUM_STAGES = 2
) (
  // Source domain
  input  logic clk_src_i,
  input  logic rst_src_ni,
  input  logic pulse_src_i,
  // Destination domain
  input  logic clk_dst_i,
  input  logic rst_dst_ni,
  output logic pulse_dst_o
);

  localparam int unsigned ARM_W = NUM_STAGES + 2;

  logic             tgl_q;
  logic             tgl_s;
  logic             tgl_d_q;
  logic             pulse_dst_q;
  logic [ARM_W-1:0] arm_q;

  // ---------------------------------------------------------------------------
  // Source: each pulse (clk_src) flips a level; the level crosses.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_src_i or negedge rst_src_ni) begin
    if (!rst_src_ni) begin
      tgl_q <= 1'b0;
    end else begin
      tgl_q <= tgl_q ^ pulse_src_i;
    end
  end

  cdckit_sync #(
    .WIDTH      (1),
    .NUM_STAGES (NUM_STAGES)
  ) u_sync (
    .clk_i  (clk_dst_i),
    .rst_ni (rst_dst_ni),
    .d_i    (tgl_q),
    .q_o    (tgl_s)
  );

  // ---------------------------------------------------------------------------
  // Destination: edge detector on the synchronized level to transform it into a pulse with the destination clock (clk_dst).
  //
  // Arming window: arm_q (shift register) prevents false edge detection post-destination reset.
  // If only the dest domain resets, sync flops go to 0 while source tgl_q stays 1.
  // Once sync converges back to 1, it triggers a false 0->1 edge pulse.
  // arm_q masks the output for NUM_STAGES+2 cycles until the sync stabilizes.
  // Trade-off: Legitimate pulses right after reset are lost (intentional design choice), but better than false pulses. [AI Feedback]
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_dst_i or negedge rst_dst_ni) begin
    if (!rst_dst_ni) begin
      arm_q       <= '0;
      tgl_d_q     <= 1'b0;
      pulse_dst_q <= 1'b0;
    end else begin
      arm_q       <= {arm_q[ARM_W-2:0], 1'b1};
      tgl_d_q     <= tgl_s;
      pulse_dst_q <= arm_q[ARM_W-1] & (tgl_s ^ tgl_d_q);
    end
  end

  assign pulse_dst_o = pulse_dst_q;

endmodule : cdckit_pulse_sync
