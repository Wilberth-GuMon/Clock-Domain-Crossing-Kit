# -----------------------------------------------------------------------------
# cdckit_rst_sync.xdc
# Scoped to cdckit_rst_sync: read_xdc -unmanaged -ref, PROCESSING_ORDER LATE [INTG-3]
# -----------------------------------------------------------------------------

# CDC-X02: arst_ni -> CLR of the synchronizer stages [MAS-RST-4] [MAS-XDC-4]
set_false_path -to [get_pins {u_sync/s_q_reg*/CLR}]
