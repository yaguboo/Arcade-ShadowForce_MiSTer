//============================================================================
//  Shadow Force -- 68000 wrapper around fx68k
//
//  Turns fx68k's asynchronous 68000 bus into a simple synchronous
//  request/acknowledge port, and generates the two-phase clock enables
//  fx68k needs.
//
//  Adapted from projects/vsystem/power_spikes/rtl/cpu/ps_m68k.sv, which was
//  itself adapted from NA-1/NA-2.  This is the third family to use it and the
//  DTACK handshake, the two-phase enable generation and the acknowledged-data
//  hold are all unchanged.  What is different on this board:
//
//    * CLK_DIV is 4 again, but for a different reason: 56 MHz / 4 = 14.000
//      MHz, this board's 68000 clock (28 MHz crystal / 2).  DECISIONS D1.
//
//    * interrupts are NOT autovectored the same way.  Power Spikes has one
//      interrupt and MAME autovectors it.  This board has three (raster,
//      16-line, vblank) at levels 1..3, and MAME's `set_input_line(n, ...)`
//      on a plain M68000 with no vector callback is also autovectored -- so
//      VPAn is asserted during an interrupt acknowledge here too, and the
//      level on IPL selects the vector.  docs/HARDWARE.md section 5.
//
//  fx68k (third_party/cpu/fx68k/) is (c) 2018,2021 Jorge Cwik, GPLv3, and carries one
//  local additive change inherited from NA-1/NA-2 (the dbg_d7 port).  See
//  docs/LICENSE_USAGE_REPORT.md.
//============================================================================
`default_nettype none

module sf_m68k #(
    // clk_sys ticks per 68000 clock.  56 MHz / 4 = 14.000 MHz, HW_CONFIRMED.
    parameter int CLK_DIV = 4
) (
    input  wire        clk,
    input  wire        rst,          // synchronous, active high
    input  wire        cpu_rst,      // hold the 68000 in reset (ROM download)
    input  wire        ce_en,        // global clock enable (pause / download)

    // --- simple synchronous bus -------------------------------------------
    output wire [23:1] addr,
    output wire [15:0] dout,         // 68000 -> system
    input  wire [15:0] din,          // system -> 68000
    output wire        rd,
    output wire        wr,
    output wire        uds_n,
    output wire        lds_n,
    input  wire        ack,          // one-cycle pulse: din valid / write taken

    // --- interrupts --------------------------------------------------------
    input  wire [2:0]  ipl_n,

    // --- observability -----------------------------------------------------
    output wire [2:0]  fc,
    output wire [31:0] dbg_d7,
    output wire        as_n,
    output wire        halted_n,
    output wire        iack          // interrupt acknowledge cycle in progress
);

  // ---------------------------------------------------------------------
  // Two-phase clock enables: one enPhi1 and one enPhi2 per 68000 clock,
  // half a clock apart.  CLK_DIV must be even for that to be exactly half.
  // ---------------------------------------------------------------------
  localparam int HALF = CLK_DIV / 2;
  reg [$clog2(CLK_DIV)-1:0] div;
  wire en_phi1 = ce_en && (div == 0);
  wire en_phi2 = ce_en && (div == HALF);

  always @(posedge clk) begin
    if (rst)        div <= '0;
    else if (ce_en) div <= (div == CLK_DIV - 1) ? '0 : div + 1'b1;
  end

  // ---------------------------------------------------------------------
  // fx68k
  // ---------------------------------------------------------------------
  wire        cpu_as_n, cpu_lds_n, cpu_uds_n, cpu_rw_n;
  wire [15:0] cpu_dout;
  wire [23:1] cpu_addr;
  wire        fc0, fc1, fc2;
  wire        vma_n, e_clk;

  reg  dtack_n;
  reg  [15:0] din_hold;

  // Autovector every interrupt.  MAME drives the three IRQ lines with plain
  // set_input_line() and installs no vector callback, so the 68000 takes the
  // autovector for the level it sees -- 0x64, 0x68, 0x6C for levels 1, 2, 3,
  // which is exactly the table in the driver header.  Those vectors were also
  // read straight out of the ROM by tools/build_rom.py's sibling check, so
  // this is not an assumption about what MAME meant.
  wire iack_cyc = (fc2 & fc1 & fc0);
  wire vpa_n = ~(iack_cyc & ~cpu_as_n);

  fx68k u_fx68k (
      .clk       (clk),
      .HALTn     (1'b1),
      .extReset  (rst | cpu_rst),
      .pwrUp     (rst),
      .enPhi1    (en_phi1),
      .enPhi2    (en_phi2),

      .dbg_d7    (dbg_d7),
      .eRWn      (cpu_rw_n),
      .ASn       (cpu_as_n),
      .LDSn      (cpu_lds_n),
      .UDSn      (cpu_uds_n),
      .E         (e_clk),
      .VMAn      (vma_n),

      .FC0       (fc0),
      .FC1       (fc1),
      .FC2       (fc2),
      .BGn       (),
      .oRESETn   (),
      .oHALTEDn  (halted_n),

      .DTACKn    (dtack_n),
      .VPAn      (vpa_n),
      .BERRn     (1'b1),
      .BRn       (1'b1),
      .BGACKn    (1'b1),

      .IPL0n     (ipl_n[0]),
      .IPL1n     (ipl_n[1]),
      .IPL2n     (ipl_n[2]),

      .iEdb      (din_hold),
      .oEdb      (cpu_dout),
      .eab       (cpu_addr)
  );

  // ---------------------------------------------------------------------
  // Bus cycle -> request/ack handshake.
  // ---------------------------------------------------------------------
  wire cyc = ~cpu_as_n & ~(cpu_lds_n & cpu_uds_n) & ~iack_cyc;
  reg  done;

  // The system-side contract only guarantees din in the clock where ack is
  // high.  fx68k captures its external data bus later, on an enabled Phi2
  // edge, so keep the acknowledged word stable until the next read completes.
  always @(posedge clk) begin
    if (rst | cpu_rst)  din_hold <= 16'hFFFF;
    else if (ack && rd) din_hold <= din;
  end

  always @(posedge clk) begin
    if (rst | cpu_rst) begin
      done    <= 1'b0;
      dtack_n <= 1'b1;
    end else if (!cyc) begin
      done    <= 1'b0;
      dtack_n <= 1'b1;
    end else if (ack) begin
      done    <= 1'b1;
      dtack_n <= 1'b0;
    end
  end

  assign rd    = cyc & ~done &  cpu_rw_n;
  assign wr    = cyc & ~done & ~cpu_rw_n;
  assign addr  = cpu_addr;
  assign dout  = cpu_dout;
  assign uds_n = cpu_uds_n;
  assign lds_n = cpu_lds_n;
  assign fc    = {fc2, fc1, fc0};
  assign as_n  = cpu_as_n;
  assign iack  = iack_cyc & ~cpu_as_n;

endmodule

`default_nettype wire
