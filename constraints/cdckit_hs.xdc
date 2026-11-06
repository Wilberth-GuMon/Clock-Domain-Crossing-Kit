# -----------------------------------------------------------------------------
# cdckit_hs.xdc
# Scoped to cdckit_hs: read_xdc -unmanaged -ref, PROCESSING_ORDER LATE [INTG-3]
# -----------------------------------------------------------------------------
set clk_src [get_clocks -quiet -of_objects [get_ports clk_src_i]]
set clk_dst [get_clocks -quiet -of_objects [get_ports clk_dst_i]]

# [MAS-XDC-1] [MAS-XDC-2] [MAS-XDC-3]
if {[llength $clk_src] == 1 && [llength $clk_dst] == 1 &&
    [get_property NAME $clk_src] ne [get_property NAME $clk_dst]} {
  set t_src [get_property -min PERIOD $clk_src]
  set t_dst [get_property -min PERIOD $clk_dst]

  # CDC-X04: req -> destination domain
  set_max_delay -datapath_only \
    -from [get_cells {current_state_reg[1]}] \
    -to   [get_cells {u_sync_req/s_q_reg[0][0]}] $t_dst

  # CDC-X05: ack -> source domain
  set_max_delay -datapath_only \
    -from [get_cells {ack_q_reg}] \
    -to   [get_cells {u_sync_ack/s_q_reg[0][0]}] $t_src

  # CDC-X06: qualified data bus
  set_max_delay -datapath_only \
    -from [get_cells {hold_q_reg[*]}] \
    -to   [get_cells {dst_data_q_reg[*]}] $t_dst
}
