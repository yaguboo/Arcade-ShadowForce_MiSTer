//============================================================================
//  Shadow Force -- hardware debug overlay
//  *** TEMPORARY.  REMOVE BEFORE RELEASE. ***
//
//  This factory has no simulator that can compile fx68k (root CLAUDE.md,
//  "Factory-level blocker"), so on a DE10-Nano there is no debugger, no
//  console, and a black screen means "something is wrong" and nothing more.
//  The core draws its own state as coloured blocks so one screenshot answers
//  "how far did it get".
//
//  ENCODING -- deliberately identical to NA-1/NA-2's na2_dbg and Power
//  Spikes' ps_dbg, so tools/read_overlay.py is nearly the same file for all
//  three projects and anyone who has read one overlay can read this one.
//  Power Spikes' docs/FACTORY_REUSE.md section 3 is explicit that **the
//  encoding is the asset, not the rows**:
//
//      16 cells per row, each cell one bit, BIT 15 LEFTMOST.
//      Rows are 4 px tall with the 4th line left as a dark gutter, and a
//      1 px dark gutter between cells so they stay countable in a scaled
//      screenshot.  Green = 1, dark red = 0.
//
//  ---- rows ---------------------------------------------------------------
//
//  Row 0   boot landmarks, latched.  Read this row first.
//            15 halted            14 read >= 0x080000   13 read >= 0x008000
//            12 sound latch write 11 video reg write    10 ctrl reg write
//             9 palette write      8 sprite RAM write    7 fg RAM write
//             6 bg RAM write       5 work RAM read       4 work RAM write
//             3 input read         2 fetched PC 0x55C6   1 read 0x000004
//             0 read 0x000000
//  Row 1   completed CPU reads            Row 2  completed CPU writes
//  Row 3   work RAM writes                Row 4  bg RAM writes (100000)
//  Row 5   fg RAM writes (140000)         Row 6  sprite RAM writes (142000)
//  Row 7   palette writes (180000)        Row 8  video reg writes (1C0000)
//  Row 9   control reg writes (1D0000)    Row 10 input reads (1D0020)
//  Row 11  UNMAPPED accesses  -- expected to stay ZERO
//
//  Rows 12-15 are the reset vector read back off hardware.  tools/build_rom.py
//  asserts the same four words before it writes the image, so these are the
//  second of the two readings root CLAUDE.md 1.3 asks for: if the builder
//  passed and these disagree, the fault is in the .mra or in SDRAM, not in
//  the CPU.
//  Row 12  first word read at 0x000000  -- must be 001F  (SSP high)
//  Row 13  first word read at 0x000002  -- must be FA00  (SSP low)
//  Row 14  first word read at 0x000004  -- must be 0000  (PC high)
//  Row 15  first word read at 0x000006  -- must be 55C6  (PC low)
//
//  Row 16  highest ROM WORD address fetched, bits 15:0.  Bits 18:16 do not
//          fit; row 0 flags 13 and 14 cover "got past 0x8000 / 0x80000".
//  Row 17  arbiter CPU stall clocks, saturating
//  Row 18  vblank interrupts raised (level 3)
//  Row 19  { sound_latch[7:0], screen_brt[7:0] }
//  Row 20  download words ISSUED to the memory bus (dl_req rising edges)
//  Row 21  download words ACKNOWLEDGED (dl_ack pulses)
//          Rows 20 and 21 must end EQUAL.  If 21 lags 20 and stops, the
//          memory bus stopped acknowledging, and with ioctl_wait enabled
//          that is a hang.  Two readings of one fact -- issued vs taken.
//  Row 22  SDRAM probe word A: sprites region word 0x0218038, must be 003B
//  Row 23  SDRAM probe word B: oki region word 0x0718004, must be 0004
//          A proves the 10 MB sprite region landed at the right base; B is
//          in the LAST region loaded, so it proves the whole 14.7 MB
//          download completed rather than stopping early.  Row 24 bit 12
//          says the probe actually ran -- without it, 0000 here means
//          either "the region is zeros" or "the probe never got the bus",
//          and those need different fixes.  Power Spikes lost time to
//          exactly that ambiguity.
//  Row 24  { halted_n, dl_active, pll_alive, probe_done,
//            video_enable, irq3, irq1, LINE_SEEN, dl_index }
//          bit 8 is "line_start has fired at least once", a STICKY second
//          reading of row 43's counter -- on this page, next to row 30.  If
//          bit 8 is 1 and row 43 is 0 the counter is broken; if bit 8 is 0
//          the CRTC really is stopped and row 30 is the lie.
//          pll_alive toggles while the PLL's spare output runs; it is the
//          load that stops Quartus deleting that output.
//  Row 25  the LOWEST program address the CPU read last frame, addr[19:4].
//  Row 26  the HIGHEST, same scale.  16 bytes per count, whole 1 MB region.
//          These used to hold the address of a bus cycle the CPU was stuck
//          on, which answered the wrong question: the 68000 is not stuck.
//          It reads 16,339 times a frame and writes twice, which is a spin
//          loop (DEBUG_LOG A13), and two separate attempts to give it more
//          bus changed nothing.  So the rows name WHERE IT IS EXECUTING, and
//          a narrow span between them can be looked up in the ROM directly.
//          The saturating stall COUNT stays on row 17; "did it ever wedge"
//          is still worth asking, it just is not this.
//  Row 27  level-2 (16-line) interrupts raised
//  Row 28  level-1 (raster) interrupts raised.  Expected to stay 0 until the
//          game arms it by writing 1D0006 bit 2, and MAME's own handling of
//          this one is an approximation -- docs/MAME_NOTES.md section 1.1.
//  Row 34  { watchdog trips, worst frames since a pet }.  The high byte must
//          stay 00: a trip is the board having reset a game that was running.
//          The low byte is the margin against WD_FRAMES = 256, and it is the
//          second reading of a number MAME already gave as 25 frames.
//
//
//  ---- one counter per row, full width ------------------------------------
//
//  These were TWO PER ROW at half width once, and it cost a whole hardware
//  run: every value was a low byte, so 0000 could mean "stuck", "wrapped to
//  zero" or "never started" and nothing distinguished them.  One counter, one
//  row, all 16 bits.
//
//  Row 30  bg1 lines DROPPED   Row 31  bg1 lines COMPLETED
//  Row 41  fg  lines DROPPED   Row 42  fg  lines COMPLETED
//  Row 32  bg0 lines DROPPED   Row 33  bg0 entries TORN
//
//  Read dropped WITH completed.  Completed rising and dropped at 0 is
//  healthy; dropped rising while completed stalls is a layer giving up;
//  BOTH at zero means the layer never left idle, which is a different fault
//  entirely -- and rows 43 and 44 are what separate its two causes.
//
//  Row 43  line_start pulses.  0 = the CRTC is not running, so no layer
//          could possibly have fetched anything.
//  Row 44  tile-ROM acknowledgements from the arbiter.  If 43 counts and
//          this does not, the layers are asking and the bus is not
//          answering.
//
//  Row 32  bg0 lines DROPPED (its own overrun; row 30 is bg1 and fg)
//  Row 33  bg0 map entries TORN -- a CPU write landed between the two words
//          of the entry being fetched.  bg0 is the only layer that can tear,
//          because it is the only one with a two-word entry, and the game
//          writes bg map RAM 97.6 % of the time during active display
//          (docs/HARDWARE.md 12b).  Expected to be small; if it is not, that
//          is a real difference from the PCB and not a decode bug.
//
//  ---- sound, page 2 -------------------------------------------------------
//
//  Read these IN ORDER and stop at the first one that is wrong; that is what
//  makes them a diagnosis rather than a pile of numbers.
//
//  Row 34  sound ROM word 0 as it came back from SDRAM.  Must be F3ED --
//          byte 0 is 0xF3, which is the Z80's DI and a plausible first
//          instruction.  0000 means the fetch never reached the audiocpu
//          region and the Z80 is executing whatever is there instead, which
//          counts on row 35 exactly like a healthy Z80 would.
//  Row 35  Z80 memory cycles.  0 = the Z80 never started.
//  Row 36  sound commands latched from the 68000.  0 while row 35 counts =
//          the Z80 runs but the 68000 never talks to it.
//  Row 37  YM2151 register writes.  0 while rows 35/36 count = the Z80 gets
//          the command but never reaches the chip -> port map or NMI.
//  Row 38  OKI M6295 sample fetches.  0 while row 37 counts = the FM works
//          and the sample path does not.
//  Row 39  Z80 clocks spent stalled on SDRAM.  This board runs the sound CPU
//          from SDRAM (DECISIONS D2) where Power Spikes uses BRAM; if this is
//          a large fraction of row 35, that decision was wrong and the
//          parameter to flip is SND_ROM_IN_BRAM.
//  Row 40  { snd_state, 8'd0 }  -- {HALT_n, pending, NMI_n, INT_n,
//                                  oki_bank, cache_v, fetching, pcm_busy}
//
//  THOSE LAST TWO ARE STALE and everything numbered above 38 in this header
//  with them.  The rows were renumbered when the sound page was laid out and
//  this list was not brought along; `snd_state` is not on any row at all,
//  which is why Verilator calls it unused.  **The case statement below is
//  the only authority on what a row number means.**  Live 2026-09-04:
//
//  Row 39  peak |ym_l| a frame            -- the FM alone
//  Row 40  peak |oki_snd << 2| a frame    -- the samples alone, mix scale
//  Row 41  { FM channels key-on'd, KON writes } this frame
//  Row 42  YM bus writes a frame, on the select's RISING EDGE
//
//  Row 45  CANARY, always A5A5.  If it is not, the overlay is not on screen
//          and nothing else on it means anything.
//  Row 46  { 7'd0, max_hcnt } -- the highest hcnt ever reached.
//          MUST be 447 (0x1BF).
//  Row 47  { 7'd0, max_vcnt } -- MUST be 271 (0x10F).
//  Row 48  SDRAM row HITS      -- D7a: the CAS went to an already-open row
//  Row 49  SDRAM row MISSES    -- the bank was idle, so ACTIVE + tRCD
//  Row 50  SDRAM row CONFLICTS -- the bank held a DIFFERENT row, so an extra
//          PRECHARGE that auto precharge never had to pay.  If this is a
//          large fraction of the total, D7a is costing more than it saves and
//          the per-bank tracking is thrashing.
//  Row 51  the FEWEST fg tiles finished on any line that was cut off.  fg
//          needs to reach 39 of 40.  38 is "two tiles short"; 5 is a
//          different bug altogether.  0x3F means never cut off.
//  Row 52  clocks the SDRAM spent servicing a transaction
//  Row 53  clocks it sat in S_IDLE with a request already waiting
//          The two stop together.  waste/(work+waste) is the fraction of the
//          memory path that is pure turnaround, and it is what decides
//          between a burst interface and a shorter handshake.
//
//          Every other instrument here measures something DERIVED from the
//          video counters.  These measure the counters, and because their
//          correct values are known they are canaries as well as data: if
//          max_hcnt is not 447 the CRTC is not sweeping the line it thinks
//          it is, and nothing downstream of it can be trusted.
//
//      python tools/read_overlay.py <shot.png>
//============================================================================
`default_nettype none

module sf_dbg #(
    parameter int H_VISIBLE = 320,
    parameter int V_START   = 8      // first visible screen line
) (
    input  wire        clk,
    input  wire        ce_pix,
    input  wire        enable,
    // All 51 rows are drawn at once: 51 * 4 = 204 of 240 lines.  Paging used
    // to draw 16 at a time, which hid three quarters of the instruments
    // behind an OSD bit and cost two hardware runs when that bit misdelivered
    // -- an instrument you cannot see is worse than one you do not have.
    // Historical note, do not reinstate
    // half the screen is still the game and a MAME frame can be matched.
    input  wire        rst_i,
    // The download counters need their OWN reset.  rst_i is the system reset,
    // which MiSTer HOLDS for the whole ROM download -- so counting the
    // download under it means the counters are cleared the instant the thing
    // they measure finishes.  On the first hardware run rows 20/21 read 0 and
    // 2 after 7.7 million words had been transferred.  mem_rst is the reset
    // that is NOT held during the load; sf_top passes it here.
    input  wire        rst_dl,

    input  wire [8:0]  hcnt,
    input  wire [8:0]  vcnt,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out,

    // --- what to show ------------------------------------------------------
    input  wire [23:1] cpu_addr,
    input  wire        cpu_rd,
    input  wire        cpu_wr,
    input  wire [15:0] cpu_dout,   // what the CPU is writing
    input  wire [15:0] irq3_raised, // times sf_main RAISED level 3
    input  wire        cpu_ack,
    input  wire [15:0] cpu_din,
    input  wire        halted_n,
    input  wire [15:0] cpu_stall,
    input  wire [2:0]  irq,
    input  wire [7:0]  sound_latch,
    input  wire [7:0]  screen_brt,
    input  wire        video_enable,
    input  wire [8:0]  bg0_scrolly,
    input  wire [15:0] watchdog,
    // Line-fetch health.  A layer that does not finish its line before the
    // next one starts has DROPPED that line, which is a different fault from
    // a slow one and shows up as tearing nobody can name.  DECISIONS D4 says
    // the budget is tight; these are how that stops being an opinion.
    input  wire [15:0] bg_rows,
    input  wire [15:0] bg_overrun,
    input  wire [15:0] fg_rows,
    input  wire [15:0] fg_overrun,
    input  wire [15:0] bg0_overrun,
    // Entries bg0 read while the CPU was writing them.  docs/HARDWARE.md 12b
    // predicts this is rare; this is how that stops being a prediction.
    input  wire [15:0] bg0_tear,

    // --- sound board.  Arranged so each failure reads DIFFERENTLY rather
    //     than every row going to zero at once -- the property that made
    //     Power Spikes' sound overlay usable at all.
    input  wire [15:0] snd_z80_cyc,
    input  wire [15:0] snd_ym_wr,
    input  wire [15:0] snd_pcm_fetch,
    input  wire [15:0] snd_z80_stall,
    // A25.  Four PER-FRAME sound instruments on rows whose investigations are
    // closed.  They replace, in order: the CPU address low/high water marks
    // (the CPU runs and the question they answered is settled), the OR of what
    // the vblank sprite copy read (0000 on every run since the copy was fixed),
    // and the 1D0026 ever-low bits (0 since it was added).
    input  wire [15:0] snd_jumps,
    input  wire [15:0] snd_maxdel,
    input  wire [15:0] snd_pcm_late,
    input  wire [15:0] snd_pcm_lat,
    input  wire [15:0] snd_pcm_over,
    input  wire [15:0] snd_clip,
    input  wire [15:0] snd_premax,
    input  wire [15:0] snd_oki_voice,
    input  wire [15:0] snd_stall_f,
    input  wire [15:0] snd_peak,
    input  wire [15:0] snd_z80clk,
    // Rows 39-42.  Row 29 is the peak of the MIX and therefore says the same
    // thing about "the OKI is a tenth as loud as it should be" and "the OKI
    // is silent" -- the two states the ear could not separate on 2026-09-04.
    // These are the two sources measured apart, on the scale each one enters
    // the mix on, plus what the game ASKED the FM to play.
    input  wire [15:0] snd_ym_peak,
    input  wire [15:0] snd_oki_peak,
    input  wire [15:0] snd_ym_kon,
    input  wire [15:0] snd_ym_wr_e,
    input  wire [15:0] snd_ym_drop,
    input  wire [15:0] bg0_rows,
    input  wire [15:0] snd_latch_seen,
    input  wire [15:0] snd_rom_w0,
    input  wire [7:0]  snd_state,
    // Decisive rows.  Packing two 16-bit counters into one row cost a whole
    // hardware run: every reading was a low byte, so "0000" meant "stuck",
    // "wrapped to zero" or "never started" with no way to tell them apart.
    input  wire [15:0] line_ticks,   // line_start pulses -- is the CRTC alive
    input  wire [15:0] bg_acks,      // tile-ROM acks -- is the arbiter serving
    input  wire        line_seen,    // ever fired?  second reading of row 43
    input  wire [8:0]  max_hcnt,     // must reach 447 -- the CRTC's own sweep
    input  wire [8:0]  max_vcnt,     // must reach 271
    input  wire [15:0] row_hit,      // D7a: SDRAM row hits
    input  wire [15:0] row_miss,     //      opens on an idle bank
    input  wire [15:0] row_conflict, //      opens that had to precharge
    input  wire [5:0]  fg_min_t,     // fewest fg tiles done at a cut-off
    input  wire [15:0] bus_work,   // D12: completed reads, WORST line     // clocks servicing a transaction
    input  wire [15:0] bus_waste,  // D12: clocks with demand, that same line    // clocks idle with a request waiting
    input  wire [15:0] spr_rows,     // sprite lines whose scan finished
    input  wire [15:0] spr_overrun,  // sprite lines cut off mid-scan
    input  wire [15:0] spr_blits,    // sprite tile rows blitted
    input  wire [7:0]  spr_n_act,    // enabled entries the LAST FULL scan found
    input  wire [15:0] spr_prescans, // completed prescans, cumulative
    input  wire [15:0] spr_w0_or,    // OR of word 0 over the last full scan
    input  wire [15:0] spr_src_or,   // OR of everything the vblank copy read
    input  wire [15:0] spr_port_wr,  // writes seen at the sprite RAM's own port
    input  wire [15:0] spr_port_or,  // OR of the data those writes carried
    input  wire [15:0] irq2_raised,  // level-2 IRQs raised   (cumulative)
    input  wire [15:0] irq2_acked,   // level-2 IRQs acked    (cumulative)
    input  wire [15:0] probe_a,
    input  wire [15:0] probe_b,
    input  wire        probe_done,
    input  wire        dl_active,
    input  wire        pll_alive,
    input  wire        dl_req,
    input  wire        dl_ack,
    input  wire [7:0]  dl_index
);

  localparam int CELL_W    = H_VISIBLE / 16;   // 320/16 = 20, exact
  // 4, and it is NOT free to change.  The geometry below divides by four
  // in HARDWARE -- `row_i = y[7:2]` and `gutter = y[1:0] == 3` -- so this
  // parameter, which only feeds `in_band`, MUST agree with those shifts.
  localparam int ROW_H     = 4;
  // 60 is the hard ceiling: ROW_H is 4 and the visible field is 240 lines.
  // 34 rows.  The overlay had grown to the hard ceiling of 60 with most of
  // it answering questions that closed sessions ago -- boot landmarks, the
  // reset vector, the download counters, the SDRAM probes, four free-running
  // counters that wrap too fast to difference.  Every row here is either a
  // trust anchor or a live 1st-completion criterion.
  localparam int N_ROWS    = 49;
  localparam [15:0] CANARY  = 16'hA5A5;

  // ---------------------------------------------------------------------
  // Event detection.  A bus cycle counts once, when it is acknowledged --
  // cpu_rd/cpu_wr are HELD until ack, so counting the strobe would count one
  // cycle many times and every number here would be meaningless.
  // ---------------------------------------------------------------------
  wire rdone = cpu_ack & cpu_rd;
  wire wdone = cpu_ack & cpu_wr;
  wire done  = rdone | wdone;

  // Same decode as sf_main.  Kept in step by hand; if they ever disagree,
  // row 11 (unmapped) is what notices.
  wire sel_rom  = (cpu_addr[23:20] == 4'h0);
  wire sel_bg   = (cpu_addr[23:16] == 8'h10) && (cpu_addr[15:14] == 2'b00);
  wire sel_fg   = (cpu_addr[23:16] == 8'h14) && (cpu_addr[15:13] == 3'b000);
  wire sel_spr  = (cpu_addr[23:16] == 8'h14) && (cpu_addr[15:13] == 3'b001);
  wire sel_pal  = (cpu_addr[23:16] == 8'h18) && (cpu_addr[15] == 1'b0);
  wire sel_vreg = (cpu_addr[23:16] == 8'h1C) && (cpu_addr[15:4] == 12'd0);
  wire sel_creg = (cpu_addr[23:16] == 8'h1D) && (cpu_addr[15:5] == 11'd0);
  wire sel_inp  = (cpu_addr[23:16] == 8'h1D) && (cpu_addr[15:5] == 11'd1)
                                             && (cpu_addr[4:3] == 2'b00);
  wire sel_work = (cpu_addr[23:16] == 8'h1F);
  wire mapped   = sel_rom | sel_bg | sel_fg | sel_spr | sel_pal
                | sel_vreg | sel_creg | sel_inp | sel_work;

  reg [15:0] n_read, n_write, n_bg_w, n_fg_w, n_spr_w, n_pal_w;
  // The bus-side OR of sprite write data that used to live here is gone.  It
  // read 0xFFFF, which was the instrument's fault, not the board's: a 68000
  // byte write drives the byte onto BOTH halves of the data bus, so ORing
  // cpu_dout without masking by the byte enables mixes in the half the RAM
  // never stores.  sf_top measures it at the RAM's own port instead, masked.
  reg [15:0] n_vreg_w, n_creg_w, n_inp_r, n_unmapped;
  reg [15:0] n_dl_req, n_dl_ack;
  reg [15:0] flags;
  reg        dl_req_d;
  // stall_addr/stall_seen are gone.  They answered "what was the CPU waiting
  // on", and the answer stopped being the question: the 68000 is not waiting,
  // it reads 16,339 times a frame and writes twice (DEBUG_LOG A13).  Rows
  // 25/26 carry where it is executing instead.  The stall COUNT stays, on row
  // 17, because "did it ever wedge" is still worth one bit of a row.

  // EVERY COUNTER AND FLAG HERE NEEDS A RESET.
  //
  // Power Spikes shipped this file's ancestor without one.  The .qsf sets
  // ALLOW_POWER_UP_DONT_CARE, so an uninitialised register may come up as 1,
  // and its row 0 duly read 0x7FFF -- every boot landmark set, including one
  // whose own counter row read ZERO.  Those two come from the same condition,
  // so the pair contradicted each other, and that is what exposed it.
  // An instrument that reports success at power-up is worse than none.
  always @(posedge clk) begin
    if (rst_i) begin
      n_read <= 16'd0; n_write <= 16'd0; n_bg_w <= 16'd0;
      n_fg_w <= 16'd0; n_spr_w <= 16'd0; n_pal_w <= 16'd0; n_vreg_w <= 16'd0;
      n_creg_w <= 16'd0; n_inp_r <= 16'd0; n_unmapped <= 16'd0;
      flags <= 16'd0;
    end else begin
      // The three per-level edge counters that used to live here are gone,
      // and so is the `irq_d` delay register they were the only readers of.
      // Counting rising edges of a HELD interrupt line measures the
      // acknowledger, not the source, and returns the same 0 for "never
      // fired" and "fires constantly, never acked".  It produced a wrong
      // answer twice (A16, A20).  sf_main now counts raises and acks
      // separately and rows 18/27/28 read those.  `irq` itself is still
      // read, by row 24's live level bits.

      if (done && !mapped) n_unmapped <= n_unmapped + 16'd1;

      // ---- reads -------------------------------------------------------
      if (rdone) begin
        n_read <= n_read + 16'd1;
        if (sel_rom) begin
          if (cpu_addr[19:1] >= 19'h04000) flags[13] <= 1'b1;  // past 0x8000
          if (cpu_addr[19:1] >= 19'h40000) flags[14] <= 1'b1;  // past 0x80000
          case (cpu_addr[19:1])
            // The vector WORDS that used to be captured here went with rows
            // 12-15.  tools/build_rom.py asserts the reset vector for all
            // three sets on every build, and both clones stack at the same
            // SSP, so the image is checked before it ever reaches the board.
            // What is still worth a bit is that the CPU FETCHED them.
            19'h00000: flags[0] <= 1'b1;
            19'h00002: flags[1] <= 1'b1;
            // the reset PC itself: 0x55C6 is word address 0x2AE3
            19'h02AE3: flags[2] <= 1'b1;
            default: ;
          endcase
        end
        if (sel_work) flags[5] <= 1'b1;
        if (sel_inp) begin n_inp_r <= n_inp_r + 16'd1; flags[3] <= 1'b1; end
      end

      // ---- writes ------------------------------------------------------
      if (wdone) begin
        n_write <= n_write + 16'd1;
        if (sel_work) flags[4] <= 1'b1;   // the count moved to row 3
        if (sel_bg)   begin n_bg_w   <= n_bg_w   + 16'd1; flags[6]  <= 1'b1; end
        if (sel_fg)   begin n_fg_w   <= n_fg_w   + 16'd1; flags[7]  <= 1'b1; end
        if (sel_spr)  begin n_spr_w  <= n_spr_w  + 16'd1; flags[8]  <= 1'b1; end
        if (sel_pal)  begin n_pal_w  <= n_pal_w  + 16'd1; flags[9]  <= 1'b1; end
        if (sel_creg) begin n_creg_w <= n_creg_w + 16'd1; flags[10] <= 1'b1; end
        if (sel_vreg) begin n_vreg_w <= n_vreg_w + 16'd1; flags[11] <= 1'b1; end
        if (sel_creg && cpu_addr[4:1] == 4'd6) flags[12] <= 1'b1;
      end

      if (!halted_n) flags[15] <= 1'b1;

      // The live-stall block that used to be here is gone with stall_cnt.
      // Row 17 reads cpu_stall from the arbiter, which is the same fact
      // measured where it happens, and the CPU turned out not to be stalling
      // at all -- it reads 16,339 times a frame and writes twice.
    end
  end

  // ---------------------------------------------------------------------
  // Download counters, on their own reset.
  //
  // Two readings of one fact: words ISSUED to the memory bus against words
  // ACKNOWLEDGED by it.  They must end EQUAL.  If 21 lags 20 and stops, the
  // memory bus stopped taking them, and with ioctl_wait asserted that is a
  // hang rather than a slow load.
  // ---------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst_dl) begin
      n_dl_req <= 16'd0;
      n_dl_ack <= 16'd0;
      dl_req_d <= 1'b0;
    end else begin
      dl_req_d <= dl_req;
      if (dl_req & ~dl_req_d) n_dl_req <= n_dl_req + 16'd1;
      if (dl_ack)             n_dl_ack <= n_dl_ack + 16'd1;
    end
  end

  // r19 (sound latch / screen brightness) and r40 (snd_state) went with rows
  // 19 and 40.  Deleted rather than left driving nothing: an unread wire is a
  // project-owned Warning (10036), and this project's rule is that the count
  // does not go up.  Their inputs stay on the port list -- an unused INPUT is
  // silent, and sf_top keeps the connection for whenever a row wants them.
  // ---------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------
  wire [8:0] y = vcnt - V_START[8:0];
  wire [5:0] row_i = y[7:2];       // /ROW_H -- and ROW_H is 4 BECAUSE of this
  // Six bits, so no wrap inside the band, and the band is the whole overlay.
  wire       in_band = (y < (N_ROWS * ROW_H));   // 44 * 4 = 176 of 240 lines

  wire in_v = enable && (vcnt >= V_START[8:0]) && in_band;
  wire in_h = (hcnt < H_VISIBLE[8:0]);
  wire active = in_v && in_h;

  // CELL_W is 20 here, which unlike Power Spikes' 22 and NA-1/NA-2's 19 is
  // still not a power of two, so `/` and `%` are a real divider and modulo.
  // Affordable only because this whole file is deleted before release; do
  // not copy the pattern into the board.
  wire [6:0] row    = {1'b0, row_i};
  wire [8:0] col9   = hcnt / CELL_W[8:0];
  wire [3:0] cell_i = (col9 > 9'd15) ? 4'd15 : col9[3:0];
  wire [3:0] bit_i  = 4'd15 - cell_i;

  wire gutter = ((hcnt % CELL_W[8:0]) == 0) || (y[1:0] == 2'd3);

  // Named wires: some tools reject `expr[bit_i]` on a concatenation where
  // others accept it, and a file that will not compile takes the whole build
  // down.  NA-1/NA-2 hit exactly this.
  wire [15:0] r24 = {halted_n, dl_active, pll_alive, probe_done,
                     video_enable, irq[2], irq[0], line_seen, dl_index};
  // Where the 68000 actually IS, per frame.
  //
  // It reads 16,339 times a frame and writes twice (DEBUG_LOG A12/A13), which
  // is a spin loop, not a starved CPU -- two separate interventions that gave
  // it more bus (D9, D10) changed nothing.  A stall ADDRESS answers "what was
  // it waiting on"; this answers the question that actually matters now,
  // "what is it executing", by bounding the addresses it touched last frame.
  //
  // addr[19:4] covers the whole 1 MB program region at 16-byte granularity.
  // If the low and high marks are equal the loop is inside sixteen bytes and
  // can be looked up in the ROM directly.
  // The 68000 program-counter water marks that used to live here are gone,
  // with rows 25 and 26, which now carry A25's sound instruments.  They
  // answered "where is the CPU executing" while it was stuck in a spin loop;
  // it has been running the game since A17 and the pair had nothing left to
  // say.  Deleted rather than left driving nothing: Quartus reports an
  // unread signal as a project-owned warning, and this project's rule is that
  // the count does not go up (root CLAUDE.md, Warning Hygiene).
  wire [15:0] r46 = {7'd0, max_hcnt};
  wire [15:0] r47 = {7'd0, max_vcnt};
  wire [15:0] r51 = {10'd0, fg_min_t};
  // n_act here is the LAST COMPLETED scan's count (sf_sprite publishes it only
  // when entry 511 is reached and never clears it), so a 0 means a finished
  // walk found nothing rather than "a walk is in progress".  128 means it hit
  // MAX_ACT and entries are being dropped.  Read it together with row 57,
  // the number of completed prescans: if that is not rising, the trigger is
  // the fault and this byte says nothing at all.
  wire [15:0] r10 = {spr_n_act, spr_blits[7:0]};

  // vbw_and stays on row 54: it is the one bit of that investigation still
  // worth a row, because a vblank flag that stopped toggling would show
  // here before anything else noticed.
  // `inp_rd` lived here and decoded the input read.  Its row went in the
  // cull and nothing else ever read it, so it was the last project-owned
  // Warning 10036 on the build.  Deleted rather than left driving nothing:
  // this project's rule is that the count does not go up (Warning Hygiene).

  // 1D0006 is irq_w: bit 0 enables interrupts, bit 3 enables video.  Hardware
  // says video_enable is 1 and no interrupt has ever fired, so the game either
  // never set bit 0 or set it and cleared it again.  The ROM contains both
  // moves -- `andi.w #$FFFE` then `move.w d0,$1D0006` clears it, `ori.w
  // #$0001` sets it -- which is MAME's "set/unset inside every trap
  // instruction" (shadfrce.cpp:511).  So the question is not what the ROM can
  // do, it is what it last did.
  //
  // Count the writes per frame, and latch the value.  Zero writes with the
  // last value lacking bit 0 means the game turned interrupts off and moved
  // on; writes every frame with bit 0 clear means something is turning them
  // off repeatedly; and bit 0 set with no interrupt firing would put the
  // fault back in sf_main rather than in the program.
  // The 1D0006 write counter and its last-value register went with rows 55/56.
  // The question they answered -- "has the game turned interrupts off" -- is
  // answered better by rows 9/10/11, which count the interrupts themselves.

  // vbw_and, the AND of every 1D0026 read, went with row 54.  It read 0 for
  // the whole of its life, which is what a sticky one-way mark does once it
  // has moved -- the same failure the PC water marks were deleted for.
  //

  // ---------------------------------------------------------------------
  // PER-FRAME rates
  //
  // A free-running 16-bit counter of line events wraps every 4.2 seconds at
  // 15,613 lines per second, and the screenshots that read it are seconds
  // apart.  So an absolute reading is ambiguous and a difference between two
  // runs is meaningless -- "watchdog writes fell 33,449 to 182" was read as
  // the CPU doing less work when the true delta was +27,687, about 3,461 per
  // second.  A whole run's conclusions rested on subtracting wrapped
  // residues (docs/DEBUG_LOG.md A11).
  //
  // Differencing at the frame boundary fixes it for every counter at once:
  // subtraction of two wrapped values is exact as long as fewer than 65,536
  // events happen between samples, and a frame is 272 lines.  The rows below
  // then read as "this many last frame", which is a number with a known right
  // answer -- 240 completed lines, 0 dropped -- instead of a running total
  // whose only use was comparing it against itself.
  // ---------------------------------------------------------------------
  // 14 slots.  Every layer now carries a COMPLETED/DROPPED pair -- the shape
  // 1.4 asks for and the one bg0 was missing when its single dropped counter
  // read 1632 and was believed.  The sprite engine was the last without one,
  // and its scan turns out to be cut off on 255 lines of 272.
  localparam int NR = 14;

  wire [15:0] rate_in [0:NR-1];
  assign rate_in[0] = n_read;
  assign rate_in[1] = n_write;
  // RAISED, not acknowledged.  n_irq3 counts rising edges of a level that
  // stays high until the CPU acks it, so once the 68000 masks interrupts
  // in its SR the edge never comes again and a per-frame delta of 0 reads
  // as "never generated" when the truth is "generated and still pending".
  // That mis-reading sent the decoder to blame sf_main (DEBUG_LOG A16).
  assign rate_in[2] = irq3_raised;   // vblank IRQs RAISED per frame
  // The same correction, applied to the row that was still wrong.  A16 fixed
  // n_irq3 and left n_irq2 counting edges, so the identical trap was still
  // armed and caught the next reading (A20).  Row 27 is now RAISES and row 28
  // is ACKNOWLEDGEMENTS, so "source stopped" and "CPU stopped servicing" are
  // different numbers instead of the same 0.
  assign rate_in[3] = irq2_raised;    // level-2 IRQs RAISED per frame
  assign rate_in[10] = irq2_acked;    // level-2 IRQs ACKNOWLEDGED per frame

  // Does the vblank-sync routine at 0x0058D0 RETURN, or is the CPU stuck in it?
  //
  // A single frame's address window cannot tell those apart: the routine waits
  // out two whole vblanks, so one snapshot legitimately falls entirely inside
  // it (A15/A20).  0x00590E is its RTS.  Counting fetches of that word per
  // frame separates the two directly -- nonzero means it returns and this is
  // an ordinary wait; a persistent zero while the vblank flag still toggles
  // means the routine never exits.
  // Cumulative -- rate_in feeds the per-frame differencer, which subtracts
  // successive readings itself.  Handing it an already-differenced value
  // would make row 58 the difference of a difference.
  // The RTS-read counter went with row 58, which now carries the Z80's
  // effective clock.
  // Slot 11 carried the RTS-read counter, whose row is now the Z80's
  // effective clock.  bg0 has had a DROPPED counter and nothing to check
  // it against since it was added -- row 32 alone is the single unchecked
  // number 1.4 forbids, and bg1 has had the pair all along (rows 30/31).
  assign rate_in[11] = bg0_rows;      // bg0 COMPLETED per frame
  assign rate_in[4]  = bg0_overrun;   // bg0 DROPPED per frame
  assign rate_in[12] = spr_rows;      // sprite scans COMPLETED per frame
  assign rate_in[13] = spr_overrun;   // sprite scans CUT OFF per frame
  assign rate_in[5] = bg_overrun;     // bg1 dropped
  assign rate_in[6] = bg_rows;        // bg1 completed
  assign rate_in[7] = fg_overrun;
  assign rate_in[8] = fg_rows;
  assign rate_in[9] = line_ticks;

  reg  [15:0] rate_prev [0:NR-1];
  reg  [15:0] rate_out  [0:NR-1];

  // Frame boundary, taken from vcnt so this needs no extra port.
  reg  [8:0] vcnt_d;
  wire       frame_tick = (vcnt_d != 9'd0) && (vcnt == 9'd0);

  integer r;
  always @(posedge clk) begin
    vcnt_d <= vcnt;
    if (frame_tick)
      for (r = 0; r < NR; r = r + 1) begin
        rate_out[r]  <= rate_in[r] - rate_prev[r];
        rate_prev[r] <= rate_in[r];
      end
  end

  reg cur;
  always @(*) begin
    case (row)
      // ---- trust anchors.  Nothing below row 3 means anything unless these
      // ---- three are exact, which is what L13 and L14 cost a run each for.
      7'd0:  cur = CANARY[bit_i];        // MUST read A5A5
      7'd1:  cur = r46[bit_i];           // max_hcnt, MUST reach 01BF (447)
      7'd2:  cur = r47[bit_i];           // max_vcnt, MUST reach 010F (271)
      7'd3:  cur = rate_out[9][bit_i];   // line_start /frame, MUST be 0110
      7'd4:  cur = r24[bit_i];           // halted/dl/pll/probe/video_enable...

      // ---- the 68000 ------------------------------------------------------
      7'd5:  cur = rate_out[0][bit_i];   // CPU reads  /frame
      7'd6:  cur = rate_out[1][bit_i];   // CPU writes /frame
      7'd7:  cur = cpu_stall[bit_i];     // CPU stall clocks, saturating
      7'd8:  cur = n_unmapped[bit_i];    // UNMAPPED accesses, MUST be 0
      7'd9:  cur = rate_out[2][bit_i];   // vblank IRQs /frame, MUST be 1
      7'd10: cur = rate_out[3][bit_i];   // level-2 RAISED /frame, MUST be 17
      7'd11: cur = rate_out[10][bit_i];  // level-2 ACKED  /frame

      // ---- the four layers, each a COMPLETED/DROPPED pair.  A single number
      // ---- with nothing to check it against is what let bg0 read 1632 and
      // ---- be believed for two sessions.
      7'd12: cur = rate_out[6][bit_i];   // bg1 COMPLETED /frame, wants 272
      7'd13: cur = rate_out[5][bit_i];   // bg1 DROPPED   /frame, wants 0
      7'd14: cur = rate_out[11][bit_i];  // bg0 COMPLETED /frame, wants 272
      7'd15: cur = rate_out[4][bit_i];   // bg0 DROPPED   /frame, wants 0
      7'd16: cur = rate_out[8][bit_i];   // fg  COMPLETED /frame, wants 272
      7'd17: cur = rate_out[7][bit_i];   // fg  DROPPED   /frame, wants 0
      7'd18: cur = r51[bit_i];           // fg tiles on its WORST line, wants 39
      7'd19: cur = rate_out[12][bit_i];  // sprite scans COMPLETED /frame
      7'd20: cur = rate_out[13][bit_i];  // sprite scans CUT OFF   /frame
      7'd21: cur = r10[bit_i];           // {n_act, blits[7:0]}

      // ---- the bus.  busy/acks on the SAME line is clocks-per-read with
      // ---- nothing inferred; the trio beside it says where the clocks go.
      7'd22: cur = bus_work[bit_i];      // completed reads, BUSIEST line
      7'd23: cur = bus_waste[bit_i];     // demand clocks, that same line
      7'd24: cur = row_hit[bit_i];       // SDRAM row hits      /frame
      7'd25: cur = row_miss[bit_i];      // SDRAM row misses    /frame
      7'd26: cur = row_conflict[bit_i];  // SDRAM row conflicts /frame

      // ---- sound.  jumps and peak together: a jump count of zero beside a
      // ---- silent peak says nothing at all.
      7'd27: cur = snd_jumps[bit_i];     // |delta| > 2048 /frame, MUST be 0
      // MAME, MEASURED ON PLAY 2026-09-04 (the old 1888/10656 pair was
      // rendered over 45 s of ATTRACT and is not this game's loud case):
      //   row 28  worst |delta| max 2006, and ZERO deltas over 2048
      //   row 29  per-frame peak  median 2363  p90 4073  p99 5177  max 5981
      7'd28: cur = snd_maxdel[bit_i];    // worst |delta| /frame (MAME max 2006)
      7'd29: cur = snd_peak[bit_i];      // peak |snd_l|  /frame (MAME med 2363)
      7'd30: cur = snd_pcm_late[bit_i];  // OKI clocked with no byte /frame
      7'd31: cur = snd_stall_f[bit_i];   // Z80 clocks STALLED /frame
      7'd32: cur = snd_z80clk[bit_i];    // Z80 cen_p /frame, wants 62313
      7'd33: cur = flags[bit_i];         // boot landmarks -- a ROM-load
                                         // regression shows here first
      // {watchdog trips, worst frames since a pet}.  The HIGH byte must stay
      // 00 -- a trip means the board reset a running game.  The low byte is
      // the same quantity MAME measured as 25 frames, read back by a different
      // mechanism, and it is the margin: near FF and the timeout is spent.
      7'd34: cur = watchdog[bit_i];
      // ---- the sound-command chain, put back 2026-09-04 -----------------
      //
      // Reported from play: the music plays and hits make no noise.  The
      // overlay could not tell which link was broken, because these three
      // were culled when it went from 60 rows to 34 -- and they are the only
      // rows that separate "the 68000 never asked" from "the Z80 never
      // played it".
      //
      // NO NEW ROUTE.  All three were still wired from sf_sound through
      // sf_top into this module and simply had no case here.  Two of this
      // session's timing failures were new 16-bit paths into the overlay, so
      // adding rows that cost none is worth more than the rows themselves.
      //
      //   35  sound commands the Z80 has taken from the latch, per frame.
      //       Flat while hitting = the command never arrived, and the fault
      //       is on the 68000 side or in the latch.
      //   36  YM2151 register writes per frame.  The music alone keeps this
      //       in the hundreds; MAME measures 522/s over the attract loop.
      //   37  M6295 sample fetches per frame.  This is the one that says
      //       whether a SAMPLE started, which row 30 cannot: row 30 counts
      //       clocks spent waiting for a fetch, so a looping drum track
      //       holds it high while no new effect ever plays.
      7'd35: cur = snd_latch_seen[bit_i];
      7'd36: cur = snd_ym_wr[bit_i];
      7'd37: cur = snd_pcm_fetch[bit_i];
      //   38  { OKI writes, OKI sample STARTS }, both saturating at FF.
      //       Row 37 counts ROM accesses and jt6295_rom polls its phrase
      //       table forever, so it says nothing about whether a sample ever
      //       started.  This does.  MAME over 57 s: 766 writes, 306 starts.
      //       No new route -- snd_rom_w0 was already wired here and unused.
      7'd38: cur = snd_rom_w0[bit_i];

      // ---- rows 39-42: which SOURCE is quiet -----------------------------
      // Row 39  peak |ym_l|          a frame -- the FM alone
      // Row 40  peak |oki_snd << 2|  a frame -- the samples alone, mix scale
      //         Row 29 is 39 and 40 added and halved, so the three together
      //         say which of the two is missing.  Both near 0 with row 36
      //         counting = the chips are being written and producing
      //         nothing; one near 0 = that source alone is gone.
      // Row 41  { channels currently HELD key-on , KON writes this frame }
      //         High byte is a bitmask, bit N = FM channel N, and it is the
      //         channels HELD, not the ones attacked this frame.  A note held
      //         across ten frames is ONE key-on and ten frames of sound, so
      //         an attack count reads 0 through most of the music.  MAME,
      //         3103 frames of real play, same definition:
      //             median 3   p90 8   max 8
      //             8 parts 13.6 % of frames, 6 parts 19.0 %, 2 parts 26.6 %
      //         while an attack appears in only 18.6 % of frames.  This is
      //         the row "I hear four or five of ten" is actually about.
      //         Low byte is KON writes, the second reading: it separates
      //         "no channel is held" from "the register is never written".
      // Row 42  YM bus writes a frame, counted on the SELECT'S RISING EDGE.
      //         Row 36 counts them on cen_p, and a Z80 write cycle spans
      //         two or three cen_p pulses -- if 42 is about half of 36 then
      //         36 has been double counting and MAME's 522 was never the
      //         number to compare it with.
      // What these should read, from MAME rendered three times over the same
      // 45 s of play -- once whole, once with the OKI's start commands
      // swallowed, once with every key-on turned into a key-off.  MAME's
      // wavs are the MIX, so they are HALF of what 39 and 40 carry: these
      // are already doubled to the pre->>1 scale the rows publish.
      //
      //   row 39  FM alone       median 3606   p90 5182   max 7876
      //   row 40  samples alone  median 2238   p90 5674   max 8068
      //
      // The OKI is above 128 in 85.5 % of MAME's frames of play, so row 40
      // reading 0 on most frames is not "a quiet moment", it is absence.
      7'd39: cur = snd_ym_peak[bit_i];
      7'd40: cur = snd_oki_peak[bit_i];
      7'd41: cur = snd_ym_kon[bit_i];
      7'd42: cur = snd_ym_wr_e[bit_i];
      // Row 43  YM writes DROPPED because the previous one had not reached
      //         its cen_p1 yet.  MUST BE 0.  The strobe is now held until
      //         that edge (jt51_mmr's busy block is gated on cen_p1 and only
      //         45 % of writes used to raise BUSY at all), and a hold needs a
      //         queue, and a queue of one that overflows is the same class of
      //         fault it was built to fix.  A Z80 memory write is 47 clocks
      //         and cen_p1 comes every 31, so this cannot fire unless
      //         something upstream changed.
      7'd43: cur = snd_ym_drop[bit_i];

      // ---- rows 44-45: how long the OKI's ROM fetch actually took --------
      // Row 44  worst single fetch this frame, in 56 MHz clocks
      // Row 45  fetches that crossed 265 clocks this frame
      //
      // 265 is not arbitrary.  jt6295_rom holds adpcm_addr for exactly two
      // cen32 slots and then takes whatever is on the bus -- it has NO
      // handshake on the sample path, only on the phrase table
      // (jt6295_rom.v:61 against :70, and that file's own header).  Two cen32
      // at 56 MHz with oki_cen at 1.6869 MHz is 265.6 clocks.
      //
      // WHAT THE TWO ROWS MEAN TOGETHER
      //   44 well under 265, 45 zero      the fetch path is NOT the fault.
      //                                   Latency is dead as a candidate and
      //                                   UPSTREAM_TODO_AUDIT U-01 is what
      //                                   is left.
      //   44 over 265, 45 non-zero        the chip is decoding bytes meant
      //                                   for other addresses, this many
      //                                   times a frame.
      //   44 under 265 but 45 non-zero    the INSTRUMENT is broken, not the
      //                                   board.  They cannot both be true.
      //
      // Row 30 cannot answer this and was read as if it could: a hundred
      // fetches one tick late and ten fetches ten ticks late give the same
      // row 30, and only the second breaks anything.  DEBUG_LOG A50.
      7'd44: cur = snd_pcm_lat[bit_i];
      7'd45: cur = snd_pcm_over[bit_i];

      // ---- rows 46-47: is the mix clipping, HERE, not in MAME ------------
      // Row 46  samples clamped by sat16 this frame
      // Row 47  worst |mix| BEFORE the clamp, saturating at FFFF
      //
      // The clipping numbers in sf_sound's mix block were rendered in MAME.
      // This board has two gain dials on the OSD and nobody has ever read the
      // headroom back off it.  A previous session diagnosed the reported
      // "먹먹한 소리" as the mix living against the clamp, and the OKI shift
      // has changed twice since, so that diagnosis is neither confirmed nor
      // retired.
      //
      // Row 29 cannot answer it: it reads the SATURATED output, pins at
      // 32767, and says the same thing for "just touched the rail" and "four
      // times over it".  Row 47 is what row 29 could not be.
      //
      //   46 zero, 47 under 32767      there is headroom, clipping is dead
      //   46 non-zero                  this many samples a frame are clamped;
      //                                turn the mix dial down and it should
      //                                fall to zero
      //   46 zero but 47 == FFFF       instrument fault, they contradict
      7'd46: cur = snd_clip[bit_i];
      7'd47: cur = snd_premax[bit_i];

      // ---- row 48: OKI voices held, the one number MAME and the board
      //      can be compared on directly -------------------------------
      // High byte  most voices held at once during the frame
      // Low nibble the mask at the frame boundary
      //
      // MAME, 69 853 frames -- twenty minutes of real play,
      // tools/mame_av_frame.lua:
      //
      //     median 3    p90 4    max 4    at least one in 93.6 % of frames
      //
      // Half the game's start commands are aimed at a voice that is already
      // playing (UPSTREAM_TODO_AUDIT U-01, measured 495 of 990).  MAME and
      // FBNeo drop those; jt6295 restarts instead.  Restarting cannot RAISE
      // the count, so a board reading well under 3 is effects ending early
      // -- U-01 seen on hardware instead of in a model.
      7'd48: cur = snd_oki_voice[bit_i];
      default: cur = 1'b0;
    endcase
  end

  wire [23:0] cell_rgb = gutter ? 24'h101010
                       : cur    ? 24'h30E030
                                : 24'h401010;

  assign rgb_out = active ? cell_rgb : rgb_in;

endmodule

`default_nettype wire
