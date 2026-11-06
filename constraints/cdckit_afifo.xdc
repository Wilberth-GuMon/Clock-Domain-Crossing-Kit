# -----------------------------------------------------------------------------
# cdckit_afifo.xdc
# Scoped to cdckit_afifo: read_xdc -unmanaged -ref, PROCESSING_ORDER LATE [INTG-3]
# -----------------------------------------------------------------------------
set wclk [get_clocks -quiet -of_objects [get_ports wclk_i]]
set rclk [get_clocks -quiet -of_objects [get_ports rclk_i]]

# [MAS-XDC-1] [MAS-XDC-2] [MAS-XDC-3]
if {[llength $wclk] == 1 && [llength $rclk] == 1 &&
    [get_property NAME $wclk] ne [get_property NAME $rclk]} {
  set tw   [get_property -min PERIOD $wclk]
  set tr   [get_property -min PERIOD $rclk]
  set tmin [expr {min($tw, $tr)}]

  # CDC-X07: write Gray pointer -> read domain
  set src [get_cells {u_wptr/wgray_q_reg[*]}]
  set dst [get_cells {u_sync_w2r/s_q_reg[0][*]}]
  set_max_delay -datapath_only -from $src -to $dst $tw
  set_bus_skew                 -from $src -to $dst $tmin

  # CDC-X08: read Gray pointer -> write domain
  set src [get_cells {u_rptr/rgray_q_reg[*]}]
  set dst [get_cells {u_sync_r2w/s_q_reg[0][*]}]
  set_max_delay -datapath_only -from $src -to $dst $tr
  set_bus_skew                 -from $src -to $dst $tmin

  # CDC-X09: LUTRAM (written on wclk) -> consumers on rclk
  set_max_delay -datapath_only \
    -from [get_cells -hierarchical -filter {PRIMITIVE_SUBGROUP == LUTRAM}] \
    -to $rclk $tr
}
