//============================================================================
//  Shadow Force -- board top
//
//  This is the arcade board and nothing else.  No hps_io, no ioctl, no APF,
//  no MRA: those live in targets/, per root CLAUDE.md section 4.  What
//  crosses this boundary is a neutral memory port (mem_*), neutral inputs,
//  and video/audio out.
//
//  ---- clocking ----------------------------------------------------------
//  clk = 56.000 MHz, and both timing-critical board clocks divide from it
//  exactly:
//
//      68000    14.000 MHz   / 4    HW_CONFIRMED (28 MHz XTAL / 2)
//      pixel     7.000 MHz   / 8    28 MHz XTAL / 4
//
//  The sound section does not: this board has three unrelated crystals, so
//  the Z80/YM2151 (3.579545 MHz) and the OKI M6295 (1.6869 MHz) will be
//  fractional enables.  DECISIONS D1 has the constants and the reasoning.
//
//  ---- what is implemented -----------------------------------------------
//      68000, full address decode, all board RAM      yes
//      SDRAM controller + arbiter, ROM download       yes
//      video timing, interrupts, board registers      yes
//      sprite RAM double buffer                       yes
//      bg1 + bg0 + fg tilemaps, palette output        yes
//      Z80 + YM2151 + OKI M6295                       yes
//      sprites                                        NOT YET
//      Z80, YM2151, OKI M6295                         NOT YET
//
//  ---- how far this has actually run ---------------------------------------
//
//  CPU_BOOTING, on a DE10-Nano, 2026-09-01.  The 68000 reads its reset vector
//  correctly (001F FA00 0000 55C6, matching what tools/build_rom.py asserts),
//  is not halted, and runs the game's initialisation and main loop: 35 061
//  reads, 4 332 writes, work RAM / bg / fg / sprite / palette all written,
//  64 468 input polls, 445 watchdog writes, video enable set by the game, and
//  ZERO unmapped accesses.  Both SDRAM probes read back correct, so the whole
//  14.7 MB download landed where the builder put it.
//
//  Not verified: any pixel.  Nothing has been compared against MAME.
//============================================================================
`default_nettype none

module sf_top (
    input  wire        clk,            // 56.000 MHz
    input  wire        rst,
    input  wire        mem_rst,        // memory transport runs during load
    input  wire        pause,

    // --- neutral memory port (ROM/sample data) -----------------------------
    output wire [24:0] mem_addr,
    output wire [15:0] mem_din,
    input  wire [15:0] mem_dout,
    output wire        mem_req,
    output wire        mem_we,
    output wire [1:0]  mem_ds,
    input  wire        mem_ack,
    input  wire        mem_ack_early,   // D22b: from sf_sdram, into the arbiter
    // OUTPUT, not input.  sf_memarb drives this (assign m_handoff = early)
    // and sf_sdram consumes it; the wire only passes THROUGH this level.  It
    // was declared `input` and Quartus accepted it -- the connection resolves
    // to a plain wire and the interlock was measured working on hardware.
    // This is rejected as ASSIGNIN by the linter, and rightly: a port whose
    // declared direction is the opposite of its dataflow is the kind of thing
    // another tool, or the same tool on another target, is free to resolve
    // differently (root CLAUDE.md 7).  Found the day a simulator existed.
    output wire        mem_handoff,

    // --- download (target drives this while loading) ------------------------
    input  wire        dl_active,
    input  wire [24:0] dl_addr,
    input  wire [15:0] dl_data,
    input  wire        dl_req,
    output wire        dl_ack,

    // --- inputs, all active low --------------------------------------------
    input  wire [7:0]  in_p1,
    input  wire [7:0]  in_p2,
    input  wire [7:0]  in_extra,
    input  wire [7:0]  in_other,
    input  wire [7:0]  in_system,
    input  wire [7:0]  in_misc,
    input  wire [7:0]  dsw1,
    input  wire [7:0]  dsw2,

    // --- video --------------------------------------------------------------
    output wire [7:0]  red,
    output wire [7:0]  green,
    output wire [7:0]  blue,
    output wire        hsync,
    output wire        vsync,
    output wire        hblank,
    output wire        vblank,
    output wire        ce_pix,

    // --- audio --------------------------------------------------------------
    output wire signed [15:0] snd_l,
    output wire signed [15:0] snd_r,

    // --- debug overlay ------------------------------------------------------
    input  wire [15:0] dbg_row_hit,
    input  wire [15:0] dbg_row_miss,
    input  wire [15:0] dbg_row_conflict,
    input  wire [15:0] dbg_bus_work,
    input  wire [15:0] dbg_bus_waste,
    input  wire        dbg_enable,
    // DIAGNOSTIC: take the OKI's sample cache out of the path entirely.
    input  wire        pcm_bypass,
    // Runtime mix and cache configuration -- see sf_sound and sf_romcache.
    input  wire [1:0]  cfg_ym_gain,     // BGM volume dial
    input  wire [1:0]  cfg_oki_gain,    // SFX volume dial
    input  wire        pll_alive,
    input  wire [7:0]  dl_index,
    // sf_sdram is a SIBLING of this module at the top level, so its per-frame
    // counters need the pulse from here.
    output wire        dbg_frame,
    output wire        dbg_halted_n
);

  `include "sf_rommap.svh"

  // ---------------------------------------------------------------------
  // Forward declarations.
  //
  // Verilog tolerates a forward reference to a NET, but not to a variable,
  // and this module wires the debug overlay to things the arbiter and the
  // ROM probe declare further down.  Declaring them here keeps every
  // reference legal regardless of how strict the tool is, rather than
  // relying on the order blocks happen to appear in.
  // ---------------------------------------------------------------------
  wire        vblank_start, line_start;
  assign dbg_frame = vblank_start;
  // Everything the copy read out of sprite RAM this frame, OR'd.  Row 3 says
  // the DESTINATION is empty; this says whether the SOURCE was.  Declared up
  // here with the other forward references: this file's header warns that a
  // forward reference to a VARIABLE is not legal even where a net would be,
  // and these are written in the copy block and read by the overlay below it.
  reg  [15:0] spr_src_or, spr_src_acc;
  // Measured AT THE RAM's own write port, not on the CPU bus.
  //
  // Row 6 snoops the bus in sf_dbg and says 4864 writes; row 33 says the copy
  // reads the RAM back as all zeros.  Both can be true if the writes never
  // reach the RAM, and both can be true if they reach it carrying zeros --
  // opposite faults.  These two watch c_spr_we/c_spr_d themselves:
  //
  //   spr_port_wr == 0                     c_spr_we never asserts: routing
  //   spr_port_wr > 0, spr_port_or == 0    the game really writes zeros
  //   spr_port_wr > 0, spr_port_or != 0    data arrives, RAM reads back zero
  //
  // The data is masked by the byte enables.  Unmasked, the first version of
  // this read 0xFFFF, because a 68000 byte write drives the byte onto BOTH
  // halves of the bus and the half the RAM ignores was being OR'd in.
  //
  // spr_port_or is PER FRAME, not cumulative.  Cumulative it read 0xFFFF,
  // which one power-on RAM pattern test is enough to produce and which then
  // says nothing about any later frame -- the same way a saturating counter
  // stops being a measurement once it saturates (DEBUG_LOG A13).  Latched at
  // vblank_start so each reading describes one frame of the game's writes.
  reg  [15:0] spr_port_wr, spr_port_or, spr_port_acc;
  wire [15:0] cpu_stall;
  wire [15:0] probe_w0, probe_w1;
  wire        probe_done;
  wire [15:0] arb_dout;
  wire [24:0] tile_a, tile0_a, crom_a;
  wire        tile_req, tile_ack, crom_req, crom_ack;
  wire        tile_hold, tile0_hold, crom_hold;
  wire        tile0_req, tile0_ack;
  wire [24:0] snd_rom_a, pcm_a;
  wire [24:0] oc_a;   // to the arbiter, cached or not
  wire [15:0] oc_q;
  wire [15:0] pcm_q;
  wire        oc_rd, oc_ack;

  // ---------------------------------------------------------------------
  // The OKI gets a cache, for the same reason the Z80 got one in D16.
  //
  // MEASURED on hardware 2026-09-04, overlay row 37, while somebody played:
  // **23,000 to 28,000 sample fetches a frame.**  The chip cannot want more
  // than about 446 -- 12.8 kHz of samples at PIN7_HIGH, two nibbles a byte,
  // four channels -- so this was fifty to sixty times over.
  //
  // The cause is in jt6295 itself, and it is deliberate there.
  // jt6295_rom.v multiplexes one ROM port between the ADPCM stream and the
  // phrase table on a `cen32` state machine, so `rom_addr` ALTERNATES at
  // roughly 400 kHz between two unrelated places.  sf_sound refetches
  // whenever the word changes -- which its own comment says is what stopped
  // Power Spikes' "seventy times too often" failure -- and against an
  // alternating address that heuristic refetches every single time.
  //
  // On a bus already saturated by three tile layers and the sprite engine,
  // that means the OKI's bytes arrive late and land on the wrong channel.
  // Reported from play as hit effects and move-name voices firing on the
  // character-select screen and nothing at all inside the stage: the samples
  // are real, they are just not the ones that were asked for.
  //
  // 1024 words is the same size D16 gave the Z80 and it fits the same shape:
  // four sequential streams plus a 512-word phrase table, all of it hot, and
  // the alternation that caused the storm now hits in the cache instead of
  // reaching SDRAM.
  //
  // AND IT CAN BE SWITCHED OFF AT RUNTIME, because the person who reported
  // the fault also reported the thing that made it findable: before this
  // cache went in the effects were LOUD and at the wrong moment, and after it
  // they are at the right moment and inaudible.  STATUS already wrote down
  // that "the fix made it worse is evidence about the fix" and then nobody
  // came back to it.
  //
  // Rebuilding to test that costs eleven minutes and a reboot each way, and
  // the comparison that matters is by EAR on the same passage of the same
  // game.  A switch makes it one OSD toggle, so the answer arrives in the
  // time it takes to hit something twice.
  //
  // This is a DIAGNOSTIC, not a shipping option.  Bypassed, the OKI goes
  // straight at the arbiter and the 60x refetch storm comes back with it --
  // that is the point, it is what the board sounded like when the effects
  // were audible.
  wire        oc_byp = pcm_bypass;
  wire [24:0] occ_a;
  wire        occ_rd, occ_ack;
  wire [15:0] occ_q;

  // 1024 sets.  It was taken to 4096 to attack the starving row 30 measures
  // -- 194 median, 1569 worst, 5 % of the chip's clocks -- and that build
  // FIT but missed setup by 0.641 ns at 50 % ALM against 44 % for the 1024
  // version.  4096 valid bits are 4096 flip-flops cleared in one clock at
  // reset, and the index decode grows two bits; both land near the memory
  // path.  So the size goes back and becomes its own experiment, run alone,
  // rather than riding along with the gain dials and making it impossible to
  // say which change cost the timing.
  sf_romcache #(.AW(25)) u_okicache (
      .clk(clk), .rst(rst | dl_active),
      .c_a(pcm_a), .c_rd(pcm_req & ~oc_byp), .c_ack(occ_ack), .c_q(occ_q),
      .m_a(occ_a), .m_rd(occ_rd),            .m_ack(oc_ack),  .m_q(oc_q)
  );

  // Bypassed: sf_sound's port IS the arbiter port, exactly as it was before
  // commit d234e57.  Cached: the cache sits between them.  Nothing else in
  // either path changes, so a difference heard is a difference caused here.
  assign oc_a    = oc_byp ? pcm_a   : occ_a;
  assign oc_rd   = oc_byp ? pcm_req : occ_rd;
  assign pcm_ack = oc_byp ? oc_ack  : occ_ack;
  assign pcm_q   = oc_byp ? oc_q    : occ_q;
  wire        snd_rom_req, pcm_req;
  wire        pcm_ack;
  wire [15:1] z80c_a;
  wire        z80c_rd;
  wire [15:0] z80c_q;
  wire        snd_rom_ack;

  // ---------------------------------------------------------------------
  // Clock enables
  // ---------------------------------------------------------------------
  wire ce_en = ~pause & ~dl_active;

  // Pixel clock: 56 / 8 = 7.000 MHz exactly.  No fractional accumulator is
  // needed here, unlike Power Spikes -- this board's video and CPU come off
  // the same 28 MHz crystal.
  reg [2:0] pixdiv;
  reg       ce_pix_r;
  always @(posedge clk) begin
    if (rst) begin
      pixdiv   <= 3'd0;
      ce_pix_r <= 1'b0;
    end else begin
      pixdiv   <= pixdiv + 3'd1;
      ce_pix_r <= (pixdiv == 3'd7);
    end
  end
  assign ce_pix = ce_pix_r;

  // ---------------------------------------------------------------------
  // Board RAM shared between the CPU and the video scanner.
  //
  // True dual-port: the CPU port is free-running and the video port reads
  // once per pixel or once per line.  On the real board the video customs
  // arbitrate CPU access against the scan; here both ports are independent,
  // which is strictly more permissive.
  //
  // **MEASURED, and it is not benign for every layer.**  MAME says the game
  // writes bg map RAM 97.6 % of the time during ACTIVE DISPLAY and sprite RAM
  // 99.8 % (docs/HARDWARE.md 12b).  For bg1 that is safe -- one word per
  // tile, so a write lands cleanly either side of the read.  For bg0, which
  // has TWO words per tile, a write can land between them and produce a tile
  // carrying one entry's colour with another's number.  Decide what bg0 does
  // about that before writing it.  Sprite RAM is already covered: it is
  // double buffered (DECISIONS D5), which this measurement justifies.
  //
  // The bg RAM's B port carries BOTH background layers' map reads.  Only bg1
  // uses it today; bg0 will need a mux here, because one B port cannot serve
  // two fetchers running in the same line.  The fg layer has its own RAM and
  // therefore its own B port, so it needs no such mux.
  // ---------------------------------------------------------------------
  wire [12:0] c_bg_a;
  wire [11:0] c_fg_a, c_spr_a;
  wire [13:0] c_pal_a;
  wire [15:0] c_bg_d, c_fg_d, c_spr_d, c_pal_d;
  wire [15:0] c_bg_q, c_fg_q, c_spr_q, c_pal_q;
  wire [ 1:0] c_bg_we, c_fg_we, c_spr_we, c_pal_we;

  wire [12:0] v_bg_a;
  wire [15:0] v_bg_q;
  wire [11:0] v_fg_a;
  wire [15:0] v_fg_q;
  wire [13:0] v_pal_a;
  wire [15:0] v_pal_q;

  sf_dpram #(.AW(13)) u_bgram (
      .clk(clk),
      .a_addr(c_bg_a), .a_din(c_bg_d), .a_we(c_bg_we), .a_dout(c_bg_q),
      .b_addr(v_bg_a), .b_dout(v_bg_q));

  sf_dpram #(.AW(12)) u_fgram (
      .clk(clk),
      .a_addr(c_fg_a), .a_din(c_fg_d), .a_we(c_fg_we), .a_dout(c_fg_q),
      .b_addr(v_fg_a), .b_dout(v_fg_q));

  sf_dpram #(.AW(14)) u_palram (
      .clk(clk),
      .a_addr(c_pal_a), .a_din(c_pal_d), .a_we(c_pal_we), .a_dout(c_pal_q),
      .b_addr(v_pal_a), .b_dout(v_pal_q));

  // ---------------------------------------------------------------------
  // Sprite RAM and its display buffer.
  //
  // The board double-buffers sprite RAM: the whole 0x2000 region is copied
  // on the rising edge of vblank and the sprite engine reads the copy, so
  // the CPU may rewrite sprite RAM mid-frame without tearing.  MAME models
  // this with buffered_spriteram16 wired to screen_vblank.  HARDWARE 9.
  //
  // The copy reads through sprite RAM's **B port**, not its A port.  Muxing
  // the copy address onto the A port would have been simpler and is wrong:
  // A carries the CPU's write address too, so a CPU write landing during the
  // copy would be written to the copy's address instead of its own.  That is
  // a corruption that only appears when the game writes sprites during
  // vblank -- which is exactly when a game writes sprites.
  //
  // The copy is 4096 words and vblank is 24 lines of 448 pixel clocks at
  // 56 MHz, so there is room for it many times over.
  // ---------------------------------------------------------------------
  // copy_a is 13 bits, not 12, and the loop runs two words past the end.
  //
  // The write trails the read by one, so stopping at 0xFFF wrote through
  // 0xFFE and left word 0xFFF holding whatever the previous frame put there
  // -- entry 511's last word, and entry 511 is the sprite MAME draws on top.
  // The two extra cycles carry the trailing write out and then let it land
  // before copy_done fires, so the pulse means "the buffer is complete",
  // which is the only thing the prescan can safely start on.
  reg  [12:0] copy_a;
  reg         copy_run;
  reg         copy_done;
  wire [15:0] spr_src_q;

  sf_dpram #(.AW(12)) u_sprram (
      .clk(clk),
      .a_addr(c_spr_a), .a_din(c_spr_d), .a_we(c_spr_we), .a_dout(c_spr_q),
      .b_addr(copy_a[11:0]), .b_dout(spr_src_q));

  reg  [11:0] buf_wa;
  reg  [15:0] buf_wd;
  reg         buf_we;

  sf_dpram #(.AW(12)) u_sprbuf (
      .clk(clk),
      .a_addr(buf_wa), .a_din(buf_wd), .a_we({2{buf_we}}), .a_dout(),
      .b_addr(spr_rd_a), .b_dout(spr_rd_q));

  always @(posedge clk) begin
    if (rst) begin
      spr_port_wr  <= 16'd0;
      spr_port_or  <= 16'd0;
      spr_port_acc <= 16'd0;
    end else begin
      if (vblank_start) begin
        spr_port_or  <= spr_port_acc;
        spr_port_acc <= 16'd0;
      end
      if (|c_spr_we) begin
        spr_port_wr  <= spr_port_wr + 16'd1;
        spr_port_acc <= (vblank_start ? 16'd0 : spr_port_acc)
                      | (c_spr_d & {{8{c_spr_we[1]}}, {8{c_spr_we[0]}}});
      end
    end
  end

  always @(posedge clk) begin
    buf_we    <= 1'b0;
    copy_done <= 1'b0;
    if (rst) begin
      copy_run    <= 1'b0;
      copy_a      <= 13'd0;
      buf_wa      <= 12'd0;
      buf_wd      <= 16'd0;
      spr_src_or  <= 16'd0;
      spr_src_acc <= 16'd0;
    end else if (vblank_start) begin
      copy_run    <= 1'b1;
      copy_a      <= 13'd0;
      spr_src_acc <= 16'd0;
    end else if (copy_run) begin
      // one clock of read latency on the source port, so the write trails
      // the read address by one
      buf_wa <= copy_a[11:0] - 12'd1;
      buf_wd <= spr_src_q;
      buf_we <= (copy_a != 13'd0) && (copy_a <= 13'h1000);
      copy_a <= copy_a + 13'd1;
      spr_src_acc <= spr_src_acc | spr_src_q;
      if (copy_a == 13'h1002) begin
        copy_run   <= 1'b0;
        copy_done  <= 1'b1;
        spr_src_or <= spr_src_acc | spr_src_q;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Main CPU board
  // ---------------------------------------------------------------------
  wire [19:1] cpu_rom_a;
  wire [15:0] cpu_rom_q;
  wire        cpu_rom_rd, cpu_rom_ack;

  // The 68000's program fetch goes through a cache before it reaches the
  // arbiter.  Adopted from Power Spikes; rtl/memory/sf_romcache.sv says why,
  // with this board's own numbers.  The short version: the CPU is executing a
  // 64-byte loop 16,339 times a frame from the LOWEST priority slot behind
  // three graphics layers that already over-subscribe the line.
  wire [19:1] rc_a;
  wire [15:0] rc_q;
  wire        rc_rd, rc_ack, rc_hold;

  wire [8:0]  bg0_scrollx, bg0_scrolly, bg1_scrollx, bg1_scrolly;
  wire        video_enable;
  wire [7:0]  screen_brt, sound_latch;
  wire        sound_latch_we;
  wire [15:0] snd_z80_cyc, snd_ym_wr, snd_pcm_fetch, snd_z80_stall;
  // A25's four: the crackle counted rather than reasoned about, PER FRAME.
  wire [15:0] snd_jumps, snd_maxdel, snd_pcm_late, snd_stall_f;
  wire [15:0] snd_pcm_lat, snd_pcm_over;   // rows 44/45 -- fetch duration
  wire [15:0] snd_clip, snd_premax;        // rows 46/47 -- mix headroom
  wire [15:0] snd_oki_voice;               // row 48 -- OKI voices held
  wire [15:0] snd_peak, snd_z80clk;
  wire [15:0] snd_ym_peak, snd_oki_peak, snd_ym_kon, snd_ym_wr_e;
  wire [15:0] snd_ym_drop;
  wire [15:0] arb_line_acks, arb_line_busy;
  wire [15:0] snd_latch_seen, snd_rom_w0;
  wire [7:0]  snd_state;
  wire [8:0]  hcnt, vcnt;
  wire [2:0]  irq;
  wire [15:0] watchdog;      // driven below: {trips, worst frames since a pet}
  wire        wdog_pet;

  // ---------------------------------------------------------------------
  // Watchdog  (1D0016)
  //
  // MAME_AUDIT 6 row 3 has said since bring-up that a counted-but-inert
  // watchdog "must exist before anything is called PLAYABLE".  Building it
  // needs one number neither reference supplies: MAME writes
  // WATCHDOG_TIMER(config, "watchdog") with no time at all, and the PCB's
  // period is an RC value nobody has measured.  So the timeout is not copied,
  // it is CHOSEN -- and the only safe way to choose it is to know the longest
  // the running game ever goes without petting.  Root CLAUDE.md 5.1: that is a
  // "얼마나 자주인가" question, so it was answered by running MAME
  // (tools/mame_watchdog_gap.lua, 178 s, 1,198,951 pets):
  //
  //     reset -> first pet        1.106 s   (63 frames)  <- the real constraint
  //     worst gap while running   0.431 s   (25 frames)  during boot self-test
  //     worst gap after boot      0.24  s   (14 frames)
  //     99.96 % of gaps           under 10 ms
  //
  // The game resting 0.43 s inside its own boot is itself a hardware fact: the
  // PCB's period must be LONGER than that, or the board would reset itself
  // before it ever ran.
  //
  // 256 frames is 4.5 s -- four times the boot and ten times the worst
  // running gap.  That is deliberately generous.  A watchdog that fires during
  // play resets a working game, intermittently and scene-dependently, and on
  // MiSTer the user already has a reset button; the asymmetry is not close.
  //
  // `dl_active` holds it clear, so a slow ROM download is not a hang.
  // 1024 frames, about 18 seconds.  It was 256 -- 4.5 s -- chosen because
  // MAME's worst gap between pets was 25 frames and 256 was ten times that.
  //
  // MAME was the wrong ruler.  Hardware, read off overlay row 34 while
  // somebody played on 2026-09-04, reached **233 frames**: 91 % of the way to
  // a reset, on a game that was working.  The board's 68000 waits on SDRAM
  // that three tile layers and the sprite engine are already saturating, so
  // it is far slower through the same code than MAME is -- and "ten times the
  // MAME number" was ten times a number measured on a machine with no bus.
  //
  // Nothing legitimate pauses eighteen seconds, and a genuinely hung game
  // still recovers.  The asymmetry is not close: a watchdog that fires on a
  // working game looks exactly like the fault reported this morning, and is
  // just as hard to tell apart from a real crash.
  //
  // Why the board rests 233 frames at all is worth knowing and is NOT what
  // this number is for.  Finding that out is a separate piece of work; this
  // stops a working game resetting itself in the meantime.
  localparam int WD_FRAMES = 1024;

  // ELEVEN bits, because WD_FRAMES is 1024 and nine cannot hold it.  The
  // first cut of this raise left them at nine and `9'(WD_FRAMES)` truncates
  // 1024 to ZERO -- so `wd_cnt >= 0` is always true and the watchdog would
  // have reset the game EVERY FRAME.  A widened limit with an unwidened
  // counter does not merely fail to fire; it fires constantly.
  reg  [10:0] wd_cnt;        // frames since the last pet
  reg  [10:0] wd_worst;      // the largest wd_cnt ever reached -- the instrument
  reg  [7:0] wd_trips;       // times it actually fired.  MUST stay 0 in play
  reg  [2:0] wd_hold;        // frames of asserted reset, so the CPU restarts
  reg        vbl_d;
  wire       vbl_rise = vblank_start & ~vbl_d;
  wire       wd_rst   = |wd_hold;

  always @(posedge clk) begin
    vbl_d <= vblank_start;
    if (rst) begin
      wd_cnt <= 11'd0; wd_worst <= 11'd0; wd_trips <= 8'd0; wd_hold <= 3'd0;
    end else if (|wd_hold) begin
      // Holding the CPU down.  It cannot pet while it is in reset, so the
      // count must not run here or the watchdog would retrigger forever.
      wd_cnt <= 11'd0;
      if (vbl_rise) wd_hold <= wd_hold - 3'd1;
    end else if (wdog_pet | dl_active) begin
      wd_cnt <= 11'd0;
    end else if (vbl_rise) begin
      if (wd_cnt >= 11'(WD_FRAMES)) begin
        wd_hold  <= 3'd4;
        wd_trips <= wd_trips + 8'd1;
        wd_cnt   <= 11'd0;
      end else begin
        wd_cnt <= wd_cnt + 11'd1;
        if ((wd_cnt + 11'd1) > wd_worst) wd_worst <= wd_cnt + 11'd1;
      end
    end
  end

  // Two readings of one fact (project CLAUDE.md 1.4): the low byte is what
  // MAME measured as 25 frames, read back off the board by a different
  // mechanism, and the high byte is the thing that must never move.  A worst
  // near 256 with trips still 0 is the warning that the margin is gone.
  // wd_worst is 11 bits now and the row is 8, so it SATURATES rather than
  // wrapping: FF means 255 or more.  A wrapped 233 would have read as a
  // healthy small number, which is the failure mode this whole row exists to
  // avoid.
  assign watchdog = {wd_trips, (|wd_worst[10:8]) ? 8'hFF : wd_worst[7:0]};
  wire        flip_screen;

  wire [23:1] cpu_a;
  wire        cpu_rd, cpu_wr, cpu_ack;
  wire [15:0] cpu_din_w;
  wire [15:0] cpu_wdata;
  wire [15:0] irq3_raised;

  sf_main u_main (
      .clk(clk), .rst(rst), .ce_en(ce_en), .cpu_rst(dl_active | wd_rst),
      .rom_addr(cpu_rom_a), .rom_data(cpu_rom_q),
      .rom_rd(cpu_rom_rd), .rom_ack(cpu_rom_ack),
      .bg_addr(c_bg_a),  .bg_din(c_bg_d),  .bg_dout(c_bg_q),  .bg_we(c_bg_we),
      .fg_addr(c_fg_a),  .fg_din(c_fg_d),  .fg_dout(c_fg_q),  .fg_we(c_fg_we),
      .spr_addr(c_spr_a), .spr_din(c_spr_d), .spr_dout(c_spr_q),
      .spr_we(c_spr_we),
      .pal_addr(c_pal_a), .pal_din(c_pal_d), .pal_dout(c_pal_q),
      .pal_we(c_pal_we),
      // 1C000A bit 0.  sf_video mirrors the counters it hands the layers.
      // MAME_AUDIT 6 -- neither reference implements this faithfully.
      .bg0_scrollx(bg0_scrollx), .bg0_scrolly(bg0_scrolly),
      .bg1_scrollx(bg1_scrollx), .bg1_scrolly(bg1_scrolly),
      .flip_screen(flip_screen), .video_enable(video_enable),
      .screen_brt(screen_brt),
      .vcnt(vcnt), .hcnt(hcnt), .ce_pix(ce_pix_r),
      .sound_latch(sound_latch), .sound_latch_we(sound_latch_we),
      .in_p1(in_p1), .in_p2(in_p2), .in_extra(in_extra), .in_other(in_other),
      .in_system(in_system), .in_misc(in_misc), .dsw1(dsw1), .dsw2(dsw2),
      .dbg_addr(cpu_a), .dbg_rd(cpu_rd), .dbg_wr(cpu_wr), .dbg_ack(cpu_ack),
      .dbg_din(cpu_din_w), .dbg_dout(cpu_wdata), .dbg_d7(),
      .dbg_halted_n(dbg_halted_n), .dbg_irq(irq),
      .dbg_irq_count(irq3_raised), .wdog_pet(wdog_pet),
      .dbg_irq2_count(irq2_raised), .dbg_irq2_ack(irq2_acked)
  );

  // ---------------------------------------------------------------------
  // Video timing
  // ---------------------------------------------------------------------
  sf_crtc u_crtc (
      .clk(clk), .rst(rst), .ce_pix(ce_pix_r),
      .hcnt(hcnt), .vcnt(vcnt),
      .hblank(hblank), .vblank(vblank),
      .hsync(hsync), .vsync(vsync),
      .visible(), .vblank_start(vblank_start), .line_start(line_start)
  );

  // ---------------------------------------------------------------------
  // Video
  //
  // bg1 only so far -- the opaque back layer, the simplest of the three
  // (one word per tile, no flip).  bg0, the fg layer and sprites go into
  // sf_video's mix, and the graphics fetch budget in DECISIONS D4 has to be
  // solved before all four run in the same line.
  // ---------------------------------------------------------------------
  wire [23:0] rgb_core;
  wire [15:0] bg_rows, bg_overrun, fg_rows, fg_overrun;
  wire [15:0] bg0_overrun, bg0_tear, bg0_rows;
  wire [5:0]  fg_min_t;
  wire [15:0] spr_rows, spr_overrun, spr_blits;
  wire [7:0]  spr_n_act;
  wire [15:0] spr_prescans, spr_w0_or;
  wire [15:0] irq2_raised, irq2_acked;
  wire [11:0] spr_rd_a;
  wire [15:0] spr_rd_q;
  wire [24:0] srom_a;
  wire        srom_req, srom_ack, srom_hold;

  // Two counters that make "the layer reads 0000" answerable.  If line_ticks
  // is 0 the CRTC never ran; if it counts and bg_acks does not, the layers
  // are asking and the memory bus is not answering.  Without these, a layer
  // at zero has three possible causes and no way to choose between them.
  reg [15:0] line_ticks, bg_acks;
  // A STICKY bit for the same fact as line_ticks, by a different mechanism.
  // A latch is not a counter and will not be optimised the same way, so if
  // the two ever disagree the fault is in one of them and not in the signal.
  // They used to sit on different overlay pages, which is how a page that
  // was never drawn got read as "the CRTC is dead" -- both are on screen now.
  reg        line_seen;
  // The high-water marks of the video counters themselves.  Every instrument
  // so far has measured something DERIVED from hcnt/vcnt; this measures them.
  // They must reach 447 and 271 -- known values, so these double as canaries:
  // anything else and the CRTC is not sweeping the frame it thinks it is.
  reg [8:0]  max_hcnt, max_vcnt;
  always @(posedge clk) begin
    if (rst) begin
      line_ticks <= 16'd0;
      bg_acks    <= 16'd0;
      line_seen  <= 1'b0;
      max_hcnt   <= 9'd0;
      max_vcnt   <= 9'd0;
    end else begin
      if (hcnt > max_hcnt) max_hcnt <= hcnt;
      if (vcnt > max_vcnt) max_vcnt <= vcnt;
      if (line_start) begin
        line_ticks <= line_ticks + 16'd1;
        line_seen  <= 1'b1;
      end
      if (tile_ack) bg_acks <= bg_acks + 16'd1;
    end
  end

  sf_video #(.H_VISIBLE(320), .V_START(8), .V_VISIBLE(240), .V_TOTAL(272)) u_video (
      .clk(clk), .rst(rst), .ce_pix(ce_pix_r),
      .hcnt(hcnt), .vcnt(vcnt), .hblank(hblank), .vblank(vblank),
      .line_start(line_start),
      .video_enable(video_enable), .screen_brt(screen_brt),
      .flip_screen(flip_screen),
      .bg0_scrollx(bg0_scrollx), .bg0_scrolly(bg0_scrolly),
      .bg1_scrollx(bg1_scrollx), .bg1_scrolly(bg1_scrolly),
      .map_addr(v_bg_a), .map_data(v_bg_q),
      // the CPU's own write to the bg RAM, so bg0 can count torn entries
      .cpu_map_we(|c_bg_we), .cpu_map_a(c_bg_a),
      .pal_addr(v_pal_a), .pal_data(v_pal_q),
      .fgmap_addr(v_fg_a), .fgmap_data(v_fg_q),
      .rom_addr(tile_a), .rom_data(arb_dout),
      .rom_req(tile_req), .rom_ack(tile_ack), .rom_hold(tile_hold),
      .rom0_addr(tile0_a), .rom0_data(arb_dout),
      .rom0_req(tile0_req), .rom0_ack(tile0_ack), .rom0_hold(tile0_hold),
      .tile_base_w(TILES_BASE_W),
      .crom_addr(crom_a), .crom_data(arb_dout),
      .crom_req(crom_req), .crom_ack(crom_ack), .crom_hold(crom_hold),
      .chars_base_w(CHARS_BASE_W),
      .rgb(rgb_core),
      .dbg_rows_done(bg_rows), .dbg_overrun(bg_overrun),
      .spr_addr(spr_rd_a), .spr_data(spr_rd_q),
      .srom_addr(srom_a), .srom_data(arb_dout),
      .srom_req(srom_req), .srom_ack(srom_ack), .srom_hold(srom_hold),
      .spr_base_w(SPRITES_BASE_W[24:0]),
      .dbg_spr_rows(spr_rows), .dbg_spr_overrun(spr_overrun),
      .dbg_spr_blits(spr_blits), .dbg_spr_n_act(spr_n_act),
      .dbg_spr_prescans(spr_prescans), .dbg_spr_w0_or(spr_w0_or),
      .copy_done(copy_done),
      .dbg_fg_rows(fg_rows), .dbg_fg_overrun(fg_overrun),
      .dbg_fg_min_t(fg_min_t),
      .dbg_bg0_overrun(bg0_overrun), .dbg_bg0_tear(bg0_tear),
      .dbg_bg0_rows(bg0_rows)
  );

  wire [23:0] rgb_ovl;
  sf_dbg #(.H_VISIBLE(320), .V_START(8)) u_dbg (
      .clk(clk), .ce_pix(ce_pix_r), .enable(dbg_enable),
      .rst_i(rst), .rst_dl(mem_rst),
      .hcnt(hcnt), .vcnt(vcnt), .rgb_in(rgb_core), .rgb_out(rgb_ovl),
      .cpu_addr(cpu_a), .cpu_rd(cpu_rd), .cpu_wr(cpu_wr), .cpu_ack(cpu_ack),
      .cpu_din(cpu_din_w), .cpu_dout(cpu_wdata), .irq3_raised(irq3_raised), .halted_n(dbg_halted_n), .cpu_stall(cpu_stall),
      .irq(irq), .sound_latch(sound_latch), .screen_brt(screen_brt),
      .video_enable(video_enable), .bg0_scrolly(bg0_scrolly),
      .watchdog(watchdog),
      .bg_rows(bg_rows), .bg_overrun(bg_overrun),
      .fg_rows(fg_rows), .fg_overrun(fg_overrun),
      .bg0_overrun(bg0_overrun), .bg0_tear(bg0_tear), .bg0_rows(bg0_rows),
      .snd_z80_cyc(snd_z80_cyc), .snd_ym_wr(snd_ym_wr),
      .snd_pcm_fetch(snd_pcm_fetch), .snd_z80_stall(snd_z80_stall),
      .snd_latch_seen(snd_latch_seen), .snd_rom_w0(snd_rom_w0),
      .snd_state(snd_state),
      .snd_jumps(snd_jumps), .snd_maxdel(snd_maxdel),
      .snd_pcm_late(snd_pcm_late), .snd_stall_f(snd_stall_f),
      .snd_pcm_lat(snd_pcm_lat), .snd_pcm_over(snd_pcm_over),
      .snd_clip(snd_clip), .snd_premax(snd_premax),
      .snd_oki_voice(snd_oki_voice),
      .snd_peak(snd_peak), .snd_z80clk(snd_z80clk),
      .snd_ym_peak(snd_ym_peak), .snd_oki_peak(snd_oki_peak),
      .snd_ym_kon(snd_ym_kon),   .snd_ym_wr_e(snd_ym_wr_e),
      .snd_ym_drop(snd_ym_drop),
      .line_ticks(line_ticks), .bg_acks(bg_acks), .line_seen(line_seen),
      .max_hcnt(max_hcnt), .max_vcnt(max_vcnt),
      .row_hit(dbg_row_hit), .row_miss(dbg_row_miss),
      .row_conflict(dbg_row_conflict), .fg_min_t(fg_min_t),
      .spr_rows(spr_rows), .spr_overrun(spr_overrun),
      .spr_blits(spr_blits), .spr_n_act(spr_n_act),
      .spr_prescans(spr_prescans), .spr_w0_or(spr_w0_or),
      .spr_src_or(spr_src_or),
      .spr_port_wr(spr_port_wr), .spr_port_or(spr_port_or),
      .irq2_raised(irq2_raised), .irq2_acked(irq2_acked),
      .bus_work(arb_line_acks), .bus_waste(arb_line_busy),
      .probe_a(probe_w0), .probe_b(probe_w1), .probe_done(probe_done),
      .dl_active(dl_active), .pll_alive(pll_alive),
      .dl_req(dl_req), .dl_ack(dl_ack), .dl_index(dl_index)
  );

  assign red   = rgb_ovl[23:16];
  assign green = rgb_ovl[15:8];
  assign blue  = rgb_ovl[7:0];

  // ---------------------------------------------------------------------
  // Sound board -- Z80 + YM2151 + OKI M6295.
  //
  // The latch is ONE WAY into the Z80's NMI on this board, unlike Power
  // Spikes' two-way one; docs/HARDWARE.md section 4.  The Z80 runs from
  // SDRAM rather than BRAM (DECISIONS D2), so its fetch can stall and
  // dbg_z80_stall is there to say how much.
  // ---------------------------------------------------------------------
  sf_sound u_sound (
      .clk(clk), .rst(rst), .ce_en(ce_en), .frame(vblank_start),
      .latch(sound_latch), .latch_we(sound_latch_we),
      .rom_addr(snd_rom_a), .rom_data(z80c_q),
      .rom_req(snd_rom_req), .rom_ack(snd_rom_ack),
      .snd_base_w(AUDIOCPU_BASE_W),
      .pcm_addr(pcm_a), .pcm_data(pcm_q),
      .pcm_req(pcm_req), .pcm_ack(pcm_ack),
      .oki_base_w(OKI_BASE_W),
      .snd_l(snd_l), .snd_r(snd_r),
      .dbg_z80_cyc(snd_z80_cyc), .dbg_ym_wr(snd_ym_wr),
      .dbg_pcm_fetch(snd_pcm_fetch), .dbg_z80_stall(snd_z80_stall),
      .dbg_latch_seen(snd_latch_seen), .dbg_rom_w0(snd_rom_w0),
      .dbg_state(snd_state),
      .dbg_snd_jumps(snd_jumps), .dbg_snd_maxdel(snd_maxdel),
      .dbg_pcm_late(snd_pcm_late), .dbg_z80_stall_f(snd_stall_f),
      .dbg_pcm_lat(snd_pcm_lat), .dbg_pcm_over(snd_pcm_over),
      .dbg_clip(snd_clip), .dbg_premax(snd_premax),
      .dbg_oki_voice(snd_oki_voice),
      .dbg_snd_peak(snd_peak), .dbg_z80_clk(snd_z80clk),
      .dbg_ym_peak(snd_ym_peak), .dbg_oki_peak(snd_oki_peak),
      .dbg_ym_kon(snd_ym_kon),   .dbg_ym_wr_e(snd_ym_wr_e),
      .dbg_ym_drop(snd_ym_drop),
      .cfg_ym_gain(cfg_ym_gain), .cfg_oki_gain(cfg_oki_gain)
  );

  // ---------------------------------------------------------------------
  // ROM probe -- "is what reached SDRAM what the builder produced?"
  //
  // The .mra and tools/build_rom.py must agree byte for byte.  The 68000
  // region has a landmark that proves it (the reset vector, on overlay rows
  // 12-15); the graphics and sample regions have none, so this reads two
  // words straight back out of SDRAM after the download:
  //
  //     sprites word 0x0218038  must be 003B  -- the 10 MB region's base
  //     oki     word 0x0718004  must be 0004  -- the LAST region loaded, so
  //                                              this one proves the whole
  //                                              14.7 MB arrived
  //
  // Both addresses are expressed against the generated bases, so they cannot
  // drift out of step with tools/build_rom.py's REGIONS table.
  //
  // It borrows arbiter client 0 -- the DOWNLOAD slot, which is idle once the
  // download has finished and is the HIGHEST priority.  Power Spikes first
  // put its probe on a low-priority client and read 0000 both times, which
  // was not "the region is zeros": in a strict priority arbiter the clients
  // above it never stop asking.  probe_done (overlay row 24) is reported
  // separately so a reading of 0000 can never mean two different things.
  //
  // DO NOT wait for a falling edge of dl_active: this module is held in rst
  // for the whole download, so that edge has already happened by the time
  // reset releases and is unobservable from here.  Count out of reset.
  // ---------------------------------------------------------------------
  localparam [24:0] PROBE_A_ADDR = SPRITES_BASE_W + 25'h38;
  localparam [24:0] PROBE_B_ADDR = OKI_BASE_W     + 25'h4;

  reg [24:0] probe_addr;
  reg        probe_req;
  reg [15:0] probe_r0, probe_r1;
  reg [1:0]  probe_st;
  reg [19:0] probe_wait;

  assign probe_done = (probe_st == 2'd3);
  assign probe_w0   = probe_r0;
  assign probe_w1   = probe_r1;

  wire probe_gnt = arb_ack[0] & probe_req & ~dl_req;

  always @(posedge clk) begin
    if (rst) begin
      probe_st   <= 2'd0;
      probe_req  <= 1'b0;
      probe_r0   <= 16'd0;
      probe_r1   <= 16'd0;
      probe_addr <= 25'd0;
      probe_wait <= 20'd0;
    end else begin
      if (!dl_active && !probe_wait[19]) probe_wait <= probe_wait + 20'd1;
      case (probe_st)
        2'd0: if (probe_wait[19]) begin
                probe_addr <= PROBE_A_ADDR;
                probe_req  <= 1'b1;
                probe_st   <= 2'd1;
              end
        2'd1: if (probe_gnt) begin
                probe_r0   <= arb_dout;
                probe_addr <= PROBE_B_ADDR;
                probe_st   <= 2'd2;
              end
        2'd2: if (probe_gnt) begin
                probe_r1  <= arb_dout;
                probe_req <= 1'b0;
                probe_st  <= 2'd3;
              end
        default: ;
      endcase
    end
  end

  // ---------------------------------------------------------------------
  // Memory arbiter
  //
  // Client order matches sf_memarb's documented priority.  The sprite, oki
  // and z80 slots are permanently idle until those blocks exist; they are
  // kept rather than removed so the numbering in sf_memarb's header still
  // describes what is here.
  //
  // bg and fg have SEPARATE slots.  They fetch during the same line, so a
  // shared slot would need a hand-written mux to serialise them -- which is
  // the arbiter's whole job.
  // ---------------------------------------------------------------------
  localparam int NC = 8;
  wire [NC-1:0]    arb_req, arb_we, arb_ack;
  wire [NC-1:0]    arb_hold;
  wire [25*NC-1:0] arb_addr;
  wire [16*NC-1:0] arb_din;
  wire [2*NC-1:0]  arb_ds;

  // Each field must be exactly 25 bits.  A concatenation one field too wide
  // truncates from the MSB and silently shifts every client's address down a
  // slot, which reads as "the CPU fetches garbage".
  // sf_romcache4: 16K words, 4-way, 4-word lines filled as one held group.
  // The 1K direct-mapped sf_romcache that stood here missed ~7,100 times a
  // frame in the Tengu demo and held the 68000 to ~70 % of MAME's reads
  // (DEBUG_LOG O-TENGU); the header of sf_romcache4 has the replay numbers.
  sf_romcache4 #(.AW(19)) u_romcache (
      // Invalidated for the whole download: the ROM it caches is being
      // written during it.
      .clk(clk), .rst(rst | dl_active),
      .c_a(cpu_rom_a), .c_rd(cpu_rom_rd), .c_ack(cpu_rom_ack), .c_q(cpu_rom_q),
      .m_a(rc_a),      .m_rd(rc_rd),      .m_hold(rc_hold),
      .m_ack(rc_ack),  .m_q(rc_q)
  );

  wire [24:0] cpu_rom_word = MAINCPU_BASE_W + {6'd0, rc_a};

  //  0 download  1 sprite  2 bg1  3 bg0  4 fg  5 oki  6 z80  7 cpu
  //
  // THE OKI IS AT INDEX 1 NOW, AHEAD OF EVERY VIDEO CLIENT.
  //
  //   old   0 download  1 sprite  2 bg1  3 bg0  4 fg  5 oki  6 z80  7 cpu
  //   new   0 download  1 oki     2 sprite 3 bg1 4 bg0 5 fg  6 --   7 cpu
  //
  // Index 0 is highest.  The OKI used to sit behind all four video clients,
  // and on the real board the M6295 reads its own ROM on its own bus and
  // never waits for video at all.
  //
  // WHAT MADE THIS CERTAIN.  Rendering the SAME phrase from the SAME sample
  // ROM through our jt6295 in Verilator -- with an IDEAL ROM, one clock and
  // always valid -- and through MAME's okim6295 gives output the player
  // could not tell apart.  So the chip is right and the data is right, and
  // the only thing left between them is this bus.  Reported by ear on
  // hardware: BGM fine, hit sounds muffled.  A starved ADPCM decoder drops
  // steps, and dropped steps are exactly a loss of high frequencies.
  //
  // Cost: the OKI wants 12.8 kHz of samples, two nibbles a byte, four
  // channels -- about 140 words a frame against the video's tens of
  // thousands.  Under one per cent.
  //
  // Port 6 is free because the Z80's program ROM moved to BRAM, so nothing
  // had to be displaced to make room.
  //
  // STATIC, not a switch.  The runtime version of this needed a 200-bit
  // address mux in front of the arbiter and cost 0.5 ns of setup on a path
  // sf_memarb's own comments call tight.
  assign arb_req  = {rc_rd, 1'b0, crom_req, tile0_req,
                     tile_req, srom_req, oc_rd, dl_req | probe_req};
  assign arb_we   = {7'b0000000, dl_active};
  assign arb_addr = {cpu_rom_word,                    // 7: cpu
                     25'd0,                           // 6: free (z80 is BRAM)
                     crom_a,                          // 5: fg
                     tile0_a,                         // 4: bg0
                     tile_a,                          // 3: bg1
                     srom_a,                          // 2: sprite
                     oc_a,                            // 1: oki (cached)
                     dl_req ? dl_addr : probe_addr};  // 0: download, then probe
  // D15.  Only bg1, bg0 and fg hold.  The sprite engine drives rom_req from
  // a register and drops it at ack, so it cannot meet the contract without
  // being restructured -- and the replay says restructuring it is worth 5
  // reads a line of 100, because a sprite's ten words are five PLANES a
  // megabyte apart and holding them just moves five conflicts into one
  // grant.  DECISIONS D15 has the search.
  // D24 adds the sprite.  It could not hold before D20 made its five words
  // consecutive; A33's "worth 1.5 %" was measured on the layout that made it
  // pointless and went stale when that layout changed.
  // Hold follows the client, so it moves with it.
  // Only the video clients hold, and they moved up one place each.
  // The CPU holds too now: a cache line fill is four consecutive words.
  assign arb_hold = {rc_hold, 1'b0, crom_hold, tile0_hold, tile_hold, srom_hold, 2'b00};
  assign arb_din  = {112'd0, dl_data};
  assign arb_ds   = {14'd0, 2'b11};

  // Every acknowledge moves with its client.  Getting ONE wrong hands a
  // client another client's data -- DEBUG_LOG A8 exactly -- so all of them
  // are here together and the port order is in the comment above arb_req.
  assign dl_ack      = arb_ack[0];
  assign oc_ack      = arb_ack[1];
  assign srom_ack    = arb_ack[2];
  assign tile_ack    = arb_ack[3];
  assign tile0_ack   = arb_ack[4];
  assign crom_ack    = arb_ack[5];
  // The arbiter answers the CACHE's miss stream, not the OKI directly:
  // pcm_ack and pcm_q come from u_okicache above.
  // AND THE DATA.  This line was missing when the cache went in, so `oc_q`
  // -- the cache's fill input -- was an undriven wire.  It synthesises to
  // zero, so every entry filled with 0000 and the OKI read zeros for ever:
  // a phrase table of start=0 stop=0, a chip told to play and playing
  // nothing.  Sound effects had been wrong before the cache and were gone
  // after it, which is exactly the shape of "the cache made it worse".
  //
  // Nothing caught it.  tools/check_unconnected.py checks module PORTS, not
  // internal wires; the simulation drove its own memory model and never used
  // this line; and the Verilator run that would have said UNDRIVEN was
  // filtered to `%Error` only.  An undriven wire is legal Verilog and reads
  // as a perfectly good zero.
  assign oc_q        = arb_dout;
  // D16.  The Z80's ROM client is now the CACHE's miss stream, not the Z80's
  // fetches.  MAME says the Z80 touches 9 KB of its 64 KB ROM and 77 % of its
  // reads land in one 1 KB page, so 1024 words hold the working set: 7,524
  // SDRAM reads a frame become 29.  sf_sound's own one-word cache stays and
  // filters first; this catches what that one misses.
  //
  // Same module and same reasoning as the 68000's u_romcache above, which is
  // the point -- root CLAUDE.md 1.2, and the sibling instance is in this file.
  //
  // ---------------------------------------------------------------------
  // THE Z80 PROGRAM ROM LIVES IN BRAM.  DECISIONS D2 chose SDRAM and wrote
  // down the condition for being wrong:
  //
  //   "dbg_z80_stall counts clocks the Z80 waits on the arbiter.  If it is a
  //    material fraction of its cycles, flip the parameter on MiSTer first
  //    and leave Pocket alone."
  //
  // Measured on hardware: 30 277 to 48 679 system clocks a frame.  A Z80
  // clock is 15.6 of those and the Z80 gets 62 313 a frame, so that is 5 %
  // of its cycles -- and it is NOT spread evenly.  It concentrates exactly
  // when the sprite engine and three tile layers are busiest, which is when
  // the player hits something, which is when the sound has to be prompt.
  // Reported from play: "타격음이랑 소리랑도 타이밍이 안 맞는 듯".
  //
  // A 1024-word cache in front of a 32 768-word ROM holds three per cent of
  // it, so it cannot fix this; the whole ROM fits in 32 M10K and the board
  // has 242 spare on MiSTer.  D2's own escape hatch, taken on its own terms.
  //
  // POCKET IS UNAFFECTED and must stay that way: D2's arithmetic there was
  // 36.9 % of M10K becoming 53.5 %, past the half that root CLAUDE.md 7 says
  // forces an external-memory examination.  This is inside the MiSTer target
  // only by virtue of being a parameter that the Pocket top can leave at 0.
  // ---------------------------------------------------------------------
  reg [15:0] z80rom [0:32767];
  wire dl_z80 = dl_active && dl_req &&
                (dl_addr >= AUDIOCPU_BASE_W) &&
                (dl_addr <  AUDIOCPU_BASE_W + 25'h8000);
  always @(posedge clk) if (dl_z80) z80rom[dl_addr[14:0] - AUDIOCPU_BASE_W[14:0]] <= dl_data;

  // One clock of latency, and the same level/pulse contract sf_sound already
  // speaks: c_rd is held until the ack, so the busy flag keeps one request
  // from being acknowledged twice (the failure sf_romcache's S_DONE exists
  // for, and DEBUG_LOG A8 before it).
  reg        z80b_busy;
  reg [15:0] z80c_q_r;
  reg        snd_rom_ack_r;
  always @(posedge clk) begin
    if (rst) begin
      z80b_busy <= 1'b0; snd_rom_ack_r <= 1'b0; z80c_q_r <= 16'd0;
    end else begin
      snd_rom_ack_r <= 1'b0;
      if (snd_rom_req && !z80b_busy) begin
        // snd_rom_a is AUDIOCPU_BASE_W + the WORD index and the base's low
        // 15 bits are zero, so the index is [14:0].  The cache this replaces
        // wired `.c_a(snd_rom_a[14:0])` for the same reason; [15:1] would be
        // a byte-address slice and every fetch would come back one bit
        // shifted -- the Z80 would execute a different program.
        z80c_q_r      <= z80rom[snd_rom_a[14:0]];
        snd_rom_ack_r <= 1'b1;
        z80b_busy     <= 1'b1;
      end else if (!snd_rom_req) begin
        z80b_busy <= 1'b0;
      end
    end
  end
  assign z80c_q       = z80c_q_r;
  assign snd_rom_ack  = snd_rom_ack_r;
  assign z80c_a       = 15'd0;
  assign z80c_rd      = 1'b0;      // the arbiter's port 6 is now unused

  assign rc_ack = arb_ack[7];
  assign rc_q   = arb_dout;

  sf_memarb #(.N(NC)) u_arb (
      .clk(clk), .rst(mem_rst),
      .req(arb_req), .hold(arb_hold), .addr(arb_addr), .din(arb_din),
      .we(arb_we), .ds(arb_ds), .ack(arb_ack), .dout(arb_dout),
      .m_addr(mem_addr), .m_din(mem_din), .m_dout(mem_dout),
      .m_req(mem_req), .m_we(mem_we), .m_ds(mem_ds), .m_ack(mem_ack),
      .m_ack_early(mem_ack_early), .m_handoff(mem_handoff),
      .line_start(line_start), .frame(vblank_start), .dbg_cpu_stall(cpu_stall),
      .dbg_line_acks(arb_line_acks), .dbg_line_busy(arb_line_busy)
  );

endmodule

`default_nettype wire
