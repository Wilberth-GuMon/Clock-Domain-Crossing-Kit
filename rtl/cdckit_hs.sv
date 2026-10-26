// -----------------------------------------------------------------------------
// cdckit_hs
// Multibit transfer through a 4-phase handshake with a holding register
// Source: valid/ready. Destination: dst_valid_o pulse,
// no backpressure.
// -----------------------------------------------------------------------------
module cdckit_hs #(
  parameter int unsigned DATA_W     = 32,
  parameter int unsigned NUM_STAGES = 2
) (
  // Source domain
  input  logic              clk_src_i,
  input  logic              rst_src_ni,
  input  logic              src_valid_i,
  output logic              src_ready_o,
  input  logic [DATA_W-1:0] src_data_i,
  // Destination domain
  input  logic              clk_dst_i,
  input  logic              rst_dst_ni,
  output logic              dst_valid_o,
  output logic [DATA_W-1:0] dst_data_o
);

  // One-hot forces sequential logic: req_q is a state bit. A decoded (binary) state would put combinational logic before the
  // synchronizer, where glitches could be sampled as a false request. [AI Feedback]
  typedef enum logic [2:0] {
    S_IDLE = 3'b001,
    S_REQ  = 3'b010,
    S_DROP = 3'b100
  } state_e;

  // FSM_ENCODING = "none" keeps the written encoding. [AI Feedback]
  (* FSM_ENCODING = "none" *)
  state_e              current_state;
  state_e              nxt_state;
  logic                req_q;
  logic                ack_s;
  logic [DATA_W-1:0]   hold_q;

  logic                req_s;
  logic                ack_q;
  logic                dst_load;
  logic                dst_valid_q;
  logic [DATA_W-1:0]   dst_data_q;

  // ===========================================================================
  // Source domain
  // ===========================================================================
  always_comb begin
    nxt_state = current_state;
    case (current_state)
      // (req, ack) = (0, 0): waiting for a new word
      S_IDLE:  if (src_valid_i) nxt_state = S_REQ;    // phase 1: accept word, raise req

      // (req, ack) = (1, 0) -> (1, 1) when dst captures and raises ack (phase 2)
      S_REQ:   if (ack_s)       nxt_state = S_DROP;   // phase 3: ack seen, drop req

      // (req, ack) = (0, 1): waiting for dst to release ack
      S_DROP:  if (!ack_s)      nxt_state = S_IDLE;   // phase 4 done: ack released
      
      default:                  nxt_state = S_IDLE;
    endcase
  end

  always_ff @(posedge clk_src_i or negedge rst_src_ni) begin
    if (!rst_src_ni) begin
      current_state <= S_IDLE;
    end else begin
      current_state <= nxt_state;
    end
  end

  assign src_ready_o = current_state[0];   // S_IDLE
  assign req_q       = current_state[1];   // S_REQ

  // Holding register without reset (RST-002): loaded only in S_IDLE, so it stays stable
  // while the destination may sample it (crossing CDC-X06).
  always_ff @(posedge clk_src_i) begin
    if (src_valid_i && src_ready_o) begin
      hold_q <= src_data_i;
    end
  end

  cdckit_sync #(
    .WIDTH      (1),
    .NUM_STAGES (NUM_STAGES)
  ) u_sync_ack (
    .clk_i  (clk_src_i),
    .rst_ni (rst_src_ni),
    .d_i    (ack_q),
    .q_o    (ack_s)
  );

  // ===========================================================================
  // Destination domain
  // ===========================================================================
  cdckit_sync #(
    .WIDTH      (1),
    .NUM_STAGES (NUM_STAGES)
  ) u_sync_req (
    .clk_i  (clk_dst_i),
    .rst_ni (rst_dst_ni),
    .d_i    (req_q),
    .q_o    (req_s)
  );

  // Single capture on the rising edge of req_s; ack is req_s delayed by one cycle.
  assign dst_load = req_s & ~ack_q;

  always_ff @(posedge clk_dst_i or negedge rst_dst_ni) begin
    if (!rst_dst_ni) begin
      ack_q       <= 1'b0;
      dst_valid_q <= 1'b0;
      dst_data_q  <= '0;
    end else begin
      ack_q       <= req_s;
      dst_valid_q <= dst_load;
      if (dst_load) begin
        dst_data_q <= hold_q;
      end
    end
  end

  assign dst_valid_o = dst_valid_q;
  assign dst_data_o  = dst_data_q;

endmodule : cdckit_hs