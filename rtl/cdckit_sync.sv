// -----------------------------------------------------------------------------
// cdckit_sync
// NUM_STAGES-stage level synchronizer
// -----------------------------------------------------------------------------
module cdckit_sync #(
  parameter int unsigned       WIDTH      = 1, // Parameterizable for async FIFOs counters
  parameter int unsigned       NUM_STAGES = 2,
  parameter logic [WIDTH-1:0]  RESET_VAL  = '0
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic [WIDTH-1:0] d_i,
  output logic [WIDTH-1:0] q_o
);

  if (NUM_STAGES < 2 || NUM_STAGES > 4) begin : g_err_stages
    // Mean Time Between Failures with 4 stages means very low probability of metastability
    $fatal(1, "cdckit_sync: NUM_STAGES = %0d out of range [2:4]", NUM_STAGES); 
  end

  // ASYNC_REG: Vivado does not pack the stages into SRLs or retime them, places them in
  // the same slice (maximum resolution time), and report_cdc recognizes
  // them as a synchronizer. DONT_TOUCH prevents replication and merging [AI feedback]
  (* ASYNC_REG = "TRUE", DONT_TOUCH = "TRUE" *)
  
  logic [NUM_STAGES-1:0][WIDTH-1:0] s_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned i = 0; i < NUM_STAGES; i++) begin // Unsigned for linting purposes [AI Feedback]
        s_q[i] <= RESET_VAL;
      end
    end else begin
      s_q[0] <= d_i; // First FF = Input
      for (int unsigned i = 1; i < NUM_STAGES; i++) begin // Unsigned for linting purposes [AI Feedback]
        s_q[i] <= s_q[i-1]; // Actual FF = Previous FF
      end
    end
  end

  assign q_o = s_q[NUM_STAGES-1]; // Output = Last FF

endmodule : cdckit_sync
