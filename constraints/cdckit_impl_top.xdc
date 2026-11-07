# -----------------------------------------------------------------------------
# cdckit_impl_top.xdc
# Top-level constraints of the implementation harness (impl/cdckit_impl_top.sv)
# Expected ports: wclk_i, rclk_i, arst_ni, w_obs_o, r_obs_o, err_o
# -----------------------------------------------------------------------------

# Clocks: two independent primary inputs [MAS-XDC-5] [PERF-5]
create_clock -name wclk -period 6.400 [get_ports wclk_i]
create_clock -name rclk -period 4.000 [get_ports rclk_i]

# Clock groups
set_clock_groups -asynchronous -group [get_clocks wclk] -group [get_clocks rclk]

# Input delays: 20 % of the period, placeholder until the board is selected (OI-16)
set_input_delay -clock wclk -max 1.280 [get_ports arst_ni]
set_input_delay -clock wclk -min 0.000 [get_ports arst_ni]
set_input_delay -clock rclk -max 0.800 -add_delay [get_ports arst_ni]
set_input_delay -clock rclk -min 0.000 -add_delay [get_ports arst_ni]

# Output delays: 20 % of the period, placeholder until the board is selected (OI-16)
set_output_delay -clock wclk -max 1.280 [get_ports w_obs_o]
set_output_delay -clock wclk -min 0.000 [get_ports w_obs_o]
set_output_delay -clock rclk -max 0.800 [get_ports {r_obs_o err_o}]
set_output_delay -clock rclk -min 0.000 [get_ports {r_obs_o err_o}]

# Observation pins have no external receiver [MAS-XDC-6]
set_false_path -to [get_ports {w_obs_o r_obs_o err_o}]
