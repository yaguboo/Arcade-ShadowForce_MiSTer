derive_pll_clocks
derive_clock_uncertainty

# ---------------------------------------------------------------------------
# SDRAM
#
# There are deliberately NO set_input_delay / set_output_delay constraints on
# the SDRAM pins.  An earlier version of this file had some, invented from
# memory, and the fitter duly failed them by 3.4 ns -- a made-up requirement
# missed by a made-up margin, which tells you nothing about the board.
#
# The established MiSTer practice, checked against MiSTer-devel/NES_MiSTer
# (NES.sdc) and MiSTer-devel/Genesis_MiSTer (Genesis.sdc), is to leave the
# SDRAM pins unconstrained and set the interface timing physically, with the
# phase of the clock driven out on SDRAM_CLK.
#
# Ours is 180 degrees (rtl/pll/pll_0002.v, phase_shift1 = -8929 ps, half of
# the 17857 ps period).  At 56.000 MHz that puts the SDRAM's clock edge
# 8.93 ns after the controller's, which leaves:
#   output path  8.93 ns for FPGA clock-to-out plus board delay plus SDRAM
#               setup -- against roughly 5 ns needed
#   input path   17.86 - 8.93 = 8.93 ns for SDRAM tAC plus board delay plus
#               FPGA setup -- against roughly 7 ns needed
#
# **These margins are tighter than Power Spikes' 12.5 ns at 40 MHz**, and the
# input path in particular has under 2 ns to spare on nominal numbers.  56 MHz
# was chosen for the CPU and pixel clocks (docs/DECISIONS.md D1), not for the
# memory interface, and this is what that choice costs.  If reads come back
# corrupted on real hardware, this phase is the first thing to change and the
# clock rate is the second.
#
# The half-period shift is also what makes the read latch land three states
# after S_CMD rather than two.  See rtl/memory/sf_sdram.sv, which carries
# NA-1/NA-2's analysis of exactly that.
# UNVERIFIED ON HARDWARE: if reads come back corrupted on a real DE10-Nano,
# this phase is the first thing to change.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Framework video paths.  The scaler and the HQ2x filter are deeply pipelined
# and do not need to settle in a single core clock; the same relaxations appear
# in the reference cores above.
# ---------------------------------------------------------------------------
set_multicycle_path -to {*Hq2x*} -setup 4
set_multicycle_path -to {*Hq2x*} -hold 3

set_multicycle_path -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}] -to {ascal|*} -setup 4
set_multicycle_path -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}] -to {ascal|*} -hold 3

# ---------------------------------------------------------------------------
# clk_aux -> clk_sys is a DELIBERATE asynchronous crossing.
#
# The PLL's third output (100 MHz) exists only to force the solver into a
# legal VCO and it must have a real load, or Quartus deletes it and is free
# to re-solve the PLL somewhere else -- which is what stopped Power Spikes'
# core clock running.  Its load is a free-running counter whose top bit is sampled
# into clk_sys through a two-flop synchroniser, purely as a liveness bit for
# the debug overlay.
#
# Left unconstrained, TimeQuest times that crossing as a real 100 MHz to
# 56 MHz path and reports large negative setup slack while Fmax for the core
# clock itself is at target.  The two numbers disagreeing is what says the
# failing path is not inside the core domain.
#
# It is a synchroniser.  It must not be timed.
# ---------------------------------------------------------------------------
set_false_path   -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[2].*|divclk}]   -to   [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}]
