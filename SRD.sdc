derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# ==============================================================================
# SDRAM interface timing constraints (Round 51)
# This file used to hold only derive_pll_clocks, so SDRAM_CLK (the forwarded, 90 degree phase shifted PLL output) was never
# declared as a clock on its pin and none of the SDRAM address, control or data pins had any I/O delay: the fitter had no
# timing driven reason to place and route the SDRAM read capture (SDRAM_DQ into the clk_sys registers) correctly, which
# passes in simulation and fails on real hardware. Ported unchanged from Battlantis/Rack 'Em Up (same sdram.sv, same PLL
# phase, same hierarchy names), where it was derived with the Micron MT48LC16M16A2 datasheet numbers; see Template.sdc in the
# Battlantis repo for the long derivation and the values that were tried and rejected.
# ==============================================================================
set sdram_clk_src {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}
create_generated_clock -source $sdram_clk_src -name SDRAM_CLK [get_ports {SDRAM_CLK}]

set sdram_skew_margin 1.0
set sdram_tIS 1.5
set sdram_tIH 0.8
set sdram_tAC 5.4
set sdram_tOH 3.0

set_output_delay -clock [get_clocks {SDRAM_CLK}] -max [expr {$sdram_tIS + $sdram_skew_margin}]  [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQML SDRAM_DQMH SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_DQ[*]}]
set_output_delay -clock [get_clocks {SDRAM_CLK}] -min [expr {-($sdram_tIH + $sdram_skew_margin)}] [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQML SDRAM_DQMH SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_DQ[*]}]

set_input_delay -clock [get_clocks {SDRAM_CLK}] -max [expr {$sdram_tAC + $sdram_skew_margin}] [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock [get_clocks {SDRAM_CLK}] -min [expr {$sdram_tOH - $sdram_skew_margin}] [get_ports {SDRAM_DQ[*]}]

# The i8751 (Oregano mc8051 core inside jtframe_8751mcu) is clocked by clock enables: every register in it changes at most once per machine cycle,
# which is 72 periods of the 48 MHz clock (6 per crystal clock, divided by 12). Paths that start and end inside the MCU block therefore have far
# more than one clock period; four is a deliberately small claim. Paths from or to the rest of the design keep the single cycle constraint.
set_multicycle_path -from [get_keepers {*|jtframe_8751mcu:u_mcu|*}] -to [get_keepers {*|jtframe_8751mcu:u_mcu|*}] -setup -end 4
set_multicycle_path -from [get_keepers {*|jtframe_8751mcu:u_mcu|*}] -to [get_keepers {*|jtframe_8751mcu:u_mcu|*}] -hold -end 3
