# -----------------------------------------------------------------------------
# cdckit_pulse_sync.xdc
# Scoped to cdckit_pulse_sync: read_xdc -unmanaged -ref, PROCESSING_ORDER LATE [INTG-3]
# -----------------------------------------------------------------------------
set clk_src [get_clocks -quiet -of_objects [get_ports clk_src_i]]
set clk_dst [get_clocks -quiet -of_objects [get_ports clk_dst_i]]

# [MAS-XDC-1] [MAS-XDC-2] [MAS-XDC-3]
if {[llength $clk_src] == 1 && [llength $clk_dst] == 1 &&
    [get_property NAME $clk_src] ne [get_property NAME $clk_dst]} {
  set t_dst [get_property -min PERIOD $clk_dst]

  # CDC-X03: toggle level -> destination domain
  set_max_delay -datapath_only \
    -from [get_cells {tgl_q_reg}] \
    -to   [get_cells {u_sync/s_q_reg[0][0]}] $t_dst
}
