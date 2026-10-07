//============================================================================
//  Shadow Force -- sound board: Z80 + YM2151 + OKI M6295
//
//  docs/HARDWARE.md section 4 has the memory map.  The three things worth
//  reading before changing anything here:
//
//  1. **The latch is ONE WAY.**  MAME uses generic_latch_8 with
//     data_pending_callback wired to the Z80's NMI, and there is no path back
//     to the 68000 at all.  Power Spikes' latch is two-way with a pending
//     flag the 68000 polls; copying that wrapper across would add a register
//     the real board does not have and hide a real difference.
//     docs/FACTORY_REUSE_NOTES.md section 4.
//
//  2. **The Z80 runs from SDRAM, not BRAM** (DECISIONS D2), which is the
//     opposite of Power Spikes.  So its program fetch CAN stall, and the
//     clock enables are gated while a fetch is outstanding rather than
//     tying WAIT_n high.  Gating the enable is the safer of the two: it
//     stops the core between machine cycles instead of relying on WAIT_n
//     being sampled in the right T-state.
//
//  3. **Three unrelated crystals** (HARDWARE section 1).  The Z80 and YM2151
//     share X2 at 3.579545 MHz; the M6295 is on X4/8 = 1.6869 MHz.  Neither
//     divides out of the 56 MHz system clock, so both are fractional enables
//     with exact long-term averages -- DECISIONS D1.
//
//  jt51 is (c) Jose Tejada Gomez, GPLv3, jotego/jt51 @ 985a573.
//  jt6295 likewise, jotego/jt6295 @ 7d76b0b, and **INTERPOL must stay 0** or
//  it pulls in a file from the jtframe repository that is not vendored here.
//  docs/LICENSE_USAGE_REPORT.md.
//============================================================================
`default_nettype none

module sf_sound (
    input  wire        clk,            // 56.000 MHz
    input  wire        rst,
    input  wire        ce_en,
    // One pulse a frame, so the instruments below can be PER FRAME.  The
    // existing dbg_z80_cyc / dbg_ym_wr are free-running 16-bit counters, and
    // at 3.579545 MHz they wrap about 85 times between two screenshots 8 s
    // apart -- differencing them yields a number that looks like a rate and
    // is not.  docs/DEBUG_LOG.md A25.
    input  wire        frame,

    // --- command from the 68000 ---------------------------------------------
    input  wire [7:0]  latch,
    input  wire        latch_we,

    // --- Z80 program ROM, through the arbiter -------------------------------
    output wire [24:0] rom_addr,
    input  wire [15:0] rom_data,
    output wire        rom_req,
    input  wire        rom_ack,
    input  wire [24:0] snd_base_w,     // AUDIOCPU_BASE_W

    // --- M6295 samples, through the arbiter ---------------------------------
    output wire [24:0] pcm_addr,
    input  wire [15:0] pcm_data,
    output wire        pcm_req,
    input  wire        pcm_ack,
    input  wire [24:0] oki_base_w,     // OKI_BASE_W

    // --- audio out ------------------------------------------------------------
    output wire signed [15:0] snd_l,
    output wire signed [15:0] snd_r,

    // --- observability --------------------------------------------------------
    output reg  [15:0] dbg_z80_cyc,
    output reg  [15:0] dbg_ym_wr,
    output reg  [15:0] dbg_pcm_fetch,
    output reg  [15:0] dbg_z80_stall,
    output reg  [15:0] dbg_latch_seen,
    // WAS the sound ROM's first word, a boot check that read F3ED and has
    // been answered for months.  It is now { OKI writes, OKI sample STARTS },
    // because that is the one question left about the sound and this wire was
    // already routed all the way to sf_dbg -- and two of this session's
    // timing failures were new 16-bit paths into the overlay.
    //
    //   high byte  writes to D800.  MAME: 766 in 57 s = 13.4/s.
    //   low byte   of those, the ones that START a channel -- a 0x80|phrase
    //              followed by a second byte whose high nibble picks
    //              channels.  MAME: 306 in 57 s = 5.4/s.
    //
    // Row 37 cannot answer this: it counts ROM accesses, and jt6295_rom
    // polls its phrase table forever whether anything is playing or not.
    output reg  [15:0] dbg_rom_w0,
    output wire [7:0]  dbg_state,

    // --- the crackle, measured rather than reasoned about --------------------
    //
    // Power Spikes spent a session measuring thirteen healthy-looking suspects
    // before someone counted the thing a person actually complained about
    // (its LESSONS_LEARNED L23).  A crackle IS a discontinuity, so count
    // discontinuities.  MAME's own audio for this game, 45 s at 48 kHz:
    //
    //     |sample delta|   median 0   p99 448   p99.9 816   max 1888
    //     deltas > 2048    ZERO, in 2 160 000 samples
    //
    // so 2048 is a threshold correct Shadow Force audio never crosses, and
    // any count above zero here is an event the game does not produce.
    output reg  [15:0] dbg_snd_jumps,   // |delta| > 2048, PER FRAME
    output reg  [15:0] dbg_snd_maxdel,  // worst |delta|,  PER FRAME
    output reg  [15:0] dbg_pcm_late,    // OKI clocked with no byte, PER FRAME

    // ROW 44 / ROW 45 -- HOW LONG DID ONE SAMPLE FETCH ACTUALLY TAKE?
    //
    // Row 30 above counts oki_cen pulses spent with rom_ok low.  It cannot
    // answer this question and was read as if it could: a hundred fetches
    // each one tick late and ten fetches each ten ticks late give the SAME
    // row 30, and only the second one breaks anything.
    //
    // What breaks: jt6295_rom presents adpcm_addr for exactly two cen32
    // slots and then latches whatever is on the bus, with NO handshake --
    // rom_ok is consumed once in that file, at line 70, in the CONTROL
    // branch.  Line 61 is `adpcm_dout <= rom_data` and is ungated, and the
    // module's own header says so: "No adpcm_ok signal is generated."
    //
    // Two cen32 slots at 56 MHz with oki_cen at 1.6869 MHz is 4 * 33.196 * 2
    // = 265.6 system clocks.  Measured in sim (DEBUG_LOG A50): identical
    // output up to LAT 200, and 16 265 of 16 290 samples different at LAT
    // 260.  So the threshold is real and it is sharp.
    //
    // TWO READINGS OF ONE FACT (project CLAUDE.md 1.4).  Row 44 is the worst
    // single fetch in the frame; row 45 is how many crossed the line.  They
    // check each other: row 44 below 265 REQUIRES row 45 to read zero, and a
    // disagreement means this instrument is wrong rather than the board.
    output reg  [15:0] dbg_pcm_lat,     // worst fetch, clocks, PER FRAME
    output reg  [15:0] dbg_pcm_over,    // fetches over the window, PER FRAME

    // ROW 46 / ROW 47 -- IS THE MIX CLIPPING ON THE BOARD?
    //
    // The clipping figures written into the mix block below -- 80 samples at
    // x2, 21 160 at x4 -- were rendered in MAME.  NOBODY HAS EVER MEASURED IT
    // HERE, and the OSD has two gain dials the player has been asked to turn.
    //
    // This matters because a previous session tied the reported word to it:
    // "스피커에 물 젖은 것 같은 소리, 먹먹한 소리" was diagnosed as a mix
    // spending its loud passages against the clamp.  The shift has changed
    // twice since, so the diagnosis is neither confirmed nor retired.
    //
    // TWO READINGS AGAIN.  Row 46 counts clamped samples; row 47 is the worst
    // |mix| BEFORE the clamp.  Row 29 cannot do this -- it reads the
    // SATURATED output, so it pins at 32767 and says the same thing for
    // "just touched the rail" and "four times over it".
    output reg  [15:0] dbg_clip,        // samples hitting sat16, PER FRAME
    output reg  [15:0] dbg_premax,      // worst |mix| before sat16, PER FRAME

    // ROW 48 -- HOW MANY OKI VOICES ARE ACTUALLY PLAYING
    //
    // MAME, 69 853 frames of real play (tools/mame_av_frame.lua, 20 minutes):
    //
    //     voices held   median 3   p90 4   max 4
    //     at least one voice playing in 93.6 % of frames
    //
    // There is no row for this and it is the single most comparable audio
    // statistic on the chip.  It is also the direct board-side measurement of
    // UPSTREAM_TODO_AUDIT U-01: half the game's start commands are aimed at a
    // voice that is already playing, MAME and FBNeo drop those, and jt6295
    // restarts instead.  Restarting cannot RAISE the count -- so if the board
    // reads well under 3, effects are ending early, and that is U-01 visible
    // on hardware rather than in a model.
    //
    // High byte is the most voices held at once during the frame; low nibble
    // is the mask at the frame boundary, which is the same definition MAME's
    // row uses.  Two readings again: the max can never be less than the
    // popcount of the mask.
    output reg  [15:0] dbg_oki_voice,  // {max held, 4'd0, mask at frame}
    output reg  [15:0] dbg_z80_stall_f, // Z80 clocks stalled,     PER FRAME

    // The two readings the first cut was missing.
    //
    // dbg_snd_peak is what stops "worst |delta| = 7" from being read as
    // "smooth" when it actually means "silent" -- a delta instrument alone
    // cannot tell those apart.  (The 10 656 this line used to quote was
    // rendered over 45 s that never left attract.  Measured on PLAY on
    // 2026-09-04 the per-frame peak is median 2363, max 5981.)
    // Power Spikes carries dbg_snd_peak_l/r for exactly this reason and this
    // board did not.
    //
    // dbg_z80_clk is the Z80's EFFECTIVE speed: cen_p pulses in a frame.  The
    // stall counter saturates at 65 535 of a frame's 974 848 clocks, so it can
    // only ever say "at least 6.7 % slow".  This says how slow, exactly, and
    // it cannot saturate: 3 579 545 / 57.4449 = 62 313 per frame, which fits
    // in 16 bits with room to spare.  Anything below that IS the shortfall.
    output reg  [15:0] dbg_snd_peak,    // max |snd_l|,            PER FRAME
    output reg  [15:0] dbg_z80_clk,     // cen_p pulses (want 62 313), PER FRAME

    // ------------------------------------------------------------------
    // "Is it quiet, or is it not there?"  -- reported by ear 2026-09-04.
    //
    // `dbg_snd_peak` CANNOT ANSWER THAT.  It is the peak of the MIX, and
    // "the OKI is playing at a tenth of its level" and "the OKI is silent
    // and the YM is carrying the whole row" produce the SAME number.  That
    // is the shape STATUS calls "two states, one reading" and this board has
    // now paid for it three times (A16, A20, row 30).
    //
    // So each source gets its own peak, both on the SCALE THEY ENTER THE MIX
    // ON -- ym_l as it is, oki_snd shifted the same two places the mix
    // shifts it -- because the question is what each CONTRIBUTES, not what
    // each chip's internal full scale happens to be.  Read against row 29:
    //
    //   ym big, oki 0        the samples never reach the DAC
    //   both big, mix small  the mix or the shift is wrong, not the chips
    //   both small           nothing is being asked to play
    //   both big, mix big    the level is right and the fault is elsewhere
    //
    // `dbg_ym_kon` says what the GAME asked for, which is the other half:
    // a peak says how loud, never how many voices.
    //
    // THE HIGH BYTE IS CHANNELS CURRENTLY HELD, NOT CHANNELS KEY-ON'D THIS
    // FRAME, and the difference is the whole point.  A key-on is a NOTE
    // ATTACK: a channel holding a long note is key-on'd once and is then
    // absent from a per-frame attack count for every frame it keeps
    // sounding.  The listener counts PARTS.  Measured in MAME over 3103
    // frames of real play, attacks are in only 18.6 % of frames while the
    // number of channels actually held is
    //
    //     median 3   p90 8   max 8
    //     8 parts 13.6 % of frames, 6 parts 19.0 %, 2 parts 26.6 %
    //
    // so an attack count would have read "0" through most of the passages
    // the complaint is about.  Held is set by a key-on with a non-zero slot
    // mask and cleared by one with an empty mask, exactly as the MAME probe
    // does it, so the two numbers are the same statistic.
    //
    // The low byte still counts KON writes in the frame -- the second
    // reading, which separates "no channel is held" from "the register is
    // never written".
    //
    // `dbg_ym_wr_e` counts the same writes as row 36 but ON THE RISING EDGE
    // of the select rather than on cen_p.  mem_wr spans two or three
    // T-states and cen_p fires once per T-state, so row 36 can count one
    // bus write twice -- which is exactly the shape of its 350-915/s
    // against MAME's 522.  Two readings of one fact, per project 1.4.
    output reg  [15:0] dbg_ym_peak,     // max |ym_l|,        PER FRAME
    output reg  [15:0] dbg_oki_peak,    // max |oki_snd<<2|,  PER FRAME
    output reg  [15:0] dbg_ym_kon,      // {kon channel mask, KON writes}
    output reg  [15:0] dbg_ym_wr_e,     // YM bus writes, edge counted
    // MUST READ 0.  Z80 writes that arrived while the previous one was still
    // waiting for its cen_p1 -- a queue of one, dropping.  Anything else and
    // the alignment above has become the very fault it fixes.
    output reg  [15:0] dbg_ym_drop,

    // ------------------------------------------------------------------
    // RUNTIME MIX CONFIGURATION.  Not a shipping feature -- a way to settle
    // by ear, in one bitstream, what would otherwise be one eleven-minute
    // build per guess.  Measured attract numbers say the FM is already
    // right (board med 2737 against MAME's 2746) and the OKI is 2.7x short
    // (1860 against 5004), but the shortfall is 2.7x at the median and 1.8x
    // at p90 -- a pure gain error would be the same at both -- so the gain
    // that sounds right is not something to derive.  Try it.
    input  wire [1:0]  cfg_ym_gain,    // BGM  volume: x1 x2 x3 x4, x1 = MAME   // 0=x1  1=x2  2=x3  3=x4
    input  wire [1:0]  cfg_oki_gain    // SFX  volume: x1 x2 x3 x4, x1 = MAME
);

  // ---------------------------------------------------------------------
  // Fractional clock enables
  //
  //   Z80 / YM2151   3.579545 MHz   +1431818 mod 11200000 gives TWICE that
  //                                 rate; alternate ticks are the two phases
  //                                 T80pa wants, half a period apart.
  //   M6295          1.686900 MHz   +16869 mod 560000
  //
  // Both averages are exact.  The jitter is one 56 MHz period, 17.9 ns, on
  // a 279 ns Z80 clock -- nothing on this board can observe it.
  // ---------------------------------------------------------------------
  reg [23:0] zacc;
  reg        zphase;
  reg        ztick;
  always @(posedge clk) begin
    if (rst) begin
      zacc   <= 24'd0;
      zphase <= 1'b0;
      ztick  <= 1'b0;
    end else if (zacc + 24'd1431818 >= 24'd11200000) begin
      zacc   <= zacc + 24'd1431818 - 24'd11200000;
      zphase <= ~zphase;
      ztick  <= 1'b1;
    end else begin
      zacc  <= zacc + 24'd1431818;
      ztick <= 1'b0;
    end
  end

  // Ungated, for the FM chip: jt51 must keep running while the Z80 waits on
  // memory, exactly as the real chip does.
  wire ym_cen    = ce_en & ztick & ~zphase;      // 3.579545 MHz
  reg  ym_half;
  always @(posedge clk) if (rst) ym_half <= 1'b0; else if (ym_cen) ym_half <= ~ym_half;
  wire ym_cen_p1 = ym_cen & ym_half;             // 1.7897725 MHz, the /2 jt51 wants

  reg [19:0] oacc;
  reg        otick;
  always @(posedge clk) begin
    if (rst) begin
      oacc  <= 20'd0;
      otick <= 1'b0;
    end else if (oacc + 20'd16869 >= 20'd560000) begin
      oacc  <= oacc + 20'd16869 - 20'd560000;
      otick <= 1'b1;
    end else begin
      oacc  <= oacc + 20'd16869;
      otick <= 1'b0;
    end
  end
  wire oki_cen = ce_en & otick;

  // ---------------------------------------------------------------------
  // Reset.
  //
  // Held far longer than the chips' headers suggest, for the reason Power
  // Spikes wrote down after losing time to it: several jt* pipelines are
  // circular shift registers that initialise by shifting reset values
  // through themselves at their INTERNAL enable rate, so "6 cen cycles" is
  // an underestimate by more than an order of magnitude.  4096 system clocks
  // is 73 us here and costs nothing, because it happens once.
  // ---------------------------------------------------------------------
  reg [12:0] rst_cnt;
  wire       snd_rst = ~rst_cnt[12];
  always @(posedge clk) begin
    if (rst)              rst_cnt <= 13'd0;
    else if (~rst_cnt[12]) rst_cnt <= rst_cnt + 13'd1;
  end

  // ---------------------------------------------------------------------
  // Z80
  // ---------------------------------------------------------------------
  wire [15:0] z80_a;
  wire [7:0]  z80_do;
  reg  [7:0]  z80_di;
  wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n;
  wire        int_n, nmi_n;

  // Gate both phases together while a program fetch is outstanding.
  wire stall;
  wire cen_p = ce_en & ztick & ~zphase & ~stall;
  wire cen_n = ce_en & ztick &  zphase & ~stall;

  T80pa #(.Mode(0)) u_z80 (
      .RESET_n (~snd_rst),
      .CLK     (clk),
      .CEN_p   (cen_p),
      .CEN_n   (cen_n),
      .WAIT_n  (1'b1),        // stalling is done by gating CEN, see the header
      .INT_n   (int_n),
      .NMI_n   (nmi_n),
      .BUSRQ_n (1'b1),
      .M1_n    (m1_n),
      .MREQ_n  (mreq_n),
      .IORQ_n  (iorq_n),
      .RD_n    (rd_n),
      .WR_n    (wr_n),
      .RFSH_n  (rfsh_n),
      .HALT_n  (halt_n),
      .BUSAK_n (),
      .OUT0    (1'b0),
      .A       (z80_a),
      .DI      (z80_di),
      .DO      (z80_do),
      .REG     (),
      .DIRSet  (1'b0)
  );

  // A refresh cycle also pulls MREQ low.  Decoding it as a real access would
  // write RAM at the refresh address on every M1 -- Power Spikes' comment,
  // and it applies unchanged.
  wire mem_cy = ~mreq_n & rfsh_n;
  wire mem_rd = mem_cy & ~rd_n;
  wire mem_wr = mem_cy & ~wr_n;

  // ---------------------------------------------------------------------
  // Address decode -- HARDWARE.md section 4.
  //
  // This board has NO banked program window: 0000-BFFF is a flat 48 K of the
  // 64 K ROM.  E800 banks the SAMPLE ROM, not the program.
  // ---------------------------------------------------------------------
  wire sel_rom  = (z80_a <  16'hC000);
  wire sel_ram0 = (z80_a >= 16'hC000) && (z80_a < 16'hC800);
  wire sel_ym   = (z80_a >= 16'hC800) && (z80_a < 16'hC802);
  wire sel_oki  = (z80_a == 16'hD800);
  wire sel_lat  = (z80_a == 16'hE000);
  wire sel_bank = (z80_a == 16'hE800);
  wire sel_ram1 = (z80_a >= 16'hF000);

  // ---------------------------------------------------------------------
  // Program ROM fetch from SDRAM.
  //
  // One 16-bit word holds two program bytes, big-endian, so a byte fetch is
  // a word read plus a lane select.  A tiny one-word cache turns the common
  // case -- sequential code -- into one memory access per two bytes.
  // ---------------------------------------------------------------------
  wire [15:0] rom_byte_a = z80_a;
  wire [24:0] rom_word_a = snd_base_w + {10'd0, rom_byte_a[15:1]};

  reg  [24:0] cache_a;
  reg  [15:0] cache_d;
  reg         cache_v;
  wire        cache_hit = cache_v && (cache_a == rom_word_a);

  reg  fetching;
  assign rom_addr = rom_word_a;
  assign rom_req  = fetching;
  assign stall    = sel_rom & mem_rd & ~cache_hit;

  always @(posedge clk) begin
    if (rst | snd_rst) begin
      fetching <= 1'b0;
      cache_v  <= 1'b0;
      cache_a  <= 25'd0;
      cache_d  <= 16'd0;
    end else begin
      if (!fetching) begin
        if (sel_rom && mem_rd && !cache_hit) fetching <= 1'b1;
      end else if (rom_ack) begin
        cache_a  <= rom_word_a;
        cache_d  <= rom_data;
        cache_v  <= 1'b1;
        fetching <= 1'b0;
      end
    end
  end

  wire [7:0] rom_byte = rom_byte_a[0] ? cache_d[7:0] : cache_d[15:8];

  // ---------------------------------------------------------------------
  // Work RAM: 2 K at C000 and 4 K at F000.  Kept as one 8 K block indexed by
  // the low address bits, which is smaller than two blocks and cannot alias
  // because the two ranges differ in a[13].
  // ---------------------------------------------------------------------
  reg  [7:0] wram [0:8191];
  reg  [7:0] wram_q;
  wire [12:0] wram_a = {z80_a[13], z80_a[11:0]};
  wire        wram_sel = sel_ram0 | sel_ram1;
  always @(posedge clk) begin
    if (wram_sel && mem_wr) wram[wram_a] <= z80_do;
    wram_q <= wram[wram_a];
  end

  // ---------------------------------------------------------------------
  // Sound latch: one way, 68000 -> Z80, and the write pulses NMI.
  //
  // MAME's generic_latch_8 asserts data_pending on a write and clears it when
  // the Z80 reads the latch, with the pending line wired straight to NMI.
  // ---------------------------------------------------------------------
  reg [7:0] latch_d;
  reg       pending;
  wire      latch_rd = sel_lat & mem_rd;

  always @(posedge clk) begin
    if (rst) begin
      latch_d        <= 8'd0;
      pending        <= 1'b0;
      dbg_latch_seen <= 16'd0;
    end else begin
      if (latch_we) begin
        latch_d        <= latch;
        pending        <= 1'b1;
        dbg_latch_seen <= dbg_latch_seen + 16'd1;
      end else if (latch_rd) begin
        pending <= 1'b0;
      end
    end
  end
  assign nmi_n = ~pending;

  // ---------------------------------------------------------------------
  // YM2151
  // ---------------------------------------------------------------------
  wire [7:0] ym_dout;
  wire       ym_irq_n;
  wire signed [15:0] ym_l, ym_r;
  // ---------------------------------------------------------------------
  // THE WRITE STROBE HAS TO LAND ON A cen_p1 EDGE.
  //
  // jt51_mmr keeps two blocks.  The register file is ungated --
  //
  //     always @(posedge clk, posedge rst)      // jt51_mmr.v:131
  //         ...  if( write ) begin
  //
  // -- so a wide strobe writes the registers correctly, which is why the FM
  // sounds at all and why a peak meter never noticed anything.  BUSY is the
  // other block, and it is gated:
  //
  //     end else if(cen) begin                  // jt51_mmr.v:264
  //         busy <= write&a0 | (busy & ~nx_busy[5]);
  //
  // and that `cen` is cen_p1 -- ONE CLOCK IN EVERY 31.  So a write raises
  // BUSY only if it happens to still be asserted on that one clock.
  //
  // MEASURED, sim/tb_ym_strobe.sv, three jt51s fed identical bytes:
  //
  //     data writes issued                    332
  //     raised BUSY, strobe = whole bus cycle  150   ( 45 %)   <- was shipping
  //     raised BUSY, strobe = one clock          0   (  0 %)   <- Power Spikes
  //     raised BUSY, strobe aligned to cen_p1  332   (100 %)
  //
  // A real YM2151 raises BUSY on every data write.  Fifty-five per cent of
  // ours told the driver it was ready when the chip had not finished, and
  // the driver believes it: the game polls BUSY before the next write.
  //
  // What that costs is not the register value, it is the OPERATOR QUEUE.
  // jt51_mmr holds ONE pending operator update -- `op_din`, `up_op`, `up_ch`
  // and one `up_*` flag -- and the CSR only consumes it when the ring reaches
  // that slot, up to 32 cen_p1 later, 17.9 us.  A second write inside that
  // window overwrites the first and the first NEVER HAPPENS.
  //
  // Which is why the fault sounds like this and not like silence.  BGM sets
  // its voices slowly and re-sends them every note, so a dropped write is
  // repaired by the next one.  A sound effect writes a patch and key-ons it
  // immediately, once -- lose a TL there and that effect plays at whatever
  // level the previous one left behind.  Reported from play, 2026-09-05:
  // "0~3이 bgm 같아 나머지가 효과음이고 근데 그 효과음이 엄청 작다".
  //
  // NOTE THE DIRECTION.  Power Spikes L14 narrowed jt12's strobe to exactly
  // one clock and was right to, because jt12's register block re-executes on
  // every clock the strobe is held.  Copying that here would have taken BUSY
  // from 45 % to 0 % -- the measurement above is the only reason this went
  // the other way.  A sibling lane's fix is a hypothesis, not a patch.
  // ---------------------------------------------------------------------
  // ASSERT WITH THE BUS WRITE, HOLD UNTIL A cen_p1 HAS SEEN IT.
  //
  // The first cut of this WAITED for cen_p1 before asserting at all, which
  // fixed BUSY and BROKE THE SOUND, and only replaying the game's own
  // register stream caught it.  jt51_mmr's register file is ungated, so
  // delaying the strobe delays the WRITE -- by up to 31 clocks, which is
  // enough to push an operator update into the next CSR ring.
  //
  // MEASURED, sim/tb_ym_replay.sv, the busiest 100 ms of this game's real
  // music (636 writes, dumped from MAME with timestamps) into three jt51s:
  //
  //                            BUSY raised     output vs the shipped strobe
  //     wide (whole bus cycle)  262 / 318      --
  //     wait for cen_p1         318 / 318      differs on 4096 clocks, worst 7656
  //     assert now, hold        318 / 318      IDENTICAL, 0 of 5 067 064
  //
  // So this asserts on the same clock the shipped strobe did -- the register
  // lands at the same moment and the audio is bit-identical -- and simply
  // stays asserted until the one clock jt51_mmr's busy block looks at.  It
  // adds BUSY without moving anything else.
  reg        ymw_hold;
  reg [7:0]  ymw_din_r;
  reg        ymw_a0_r;
  reg        ymw_sel_d;
  wire       ymw_bus = sel_ym & mem_wr;
  wire       ymw_ev  = ymw_bus & ~ymw_sel_d;    // one per bus write
  wire       ymw_act = ymw_bus | ymw_hold;

  // Live off the Z80 while it drives the bus, latched afterwards -- the hold
  // can outlast the bus cycle by up to a cen_p1 and the Z80 does not promise
  // to keep driving.
  wire [7:0] ymw_din = ymw_bus ? z80_do   : ymw_din_r;
  wire       ymw_a0  = ymw_bus ? z80_a[0] : ymw_a0_r;

  always @(posedge clk) begin
    if (rst | snd_rst) begin
      ymw_hold  <= 1'b0;  ymw_sel_d <= 1'b0;
      ymw_din_r <= 8'd0;  ymw_a0_r  <= 1'b0;
      dbg_ym_drop <= 16'd0;
    end else begin
      ymw_sel_d <= ymw_bus;
      if (ymw_bus) begin
        ymw_hold  <= 1'b1;
        ymw_din_r <= z80_do;
        ymw_a0_r  <= z80_a[0];
      end else if (ym_cen_p1) begin
        ymw_hold <= 1'b0;
      end
      // A hold that is still up when the NEXT bus write starts would merge
      // two writes into one strobe.  A Z80 write is 47 clocks apart at
      // minimum and cen_p1 comes every 31, so it cannot happen -- and an
      // unmonitored "cannot happen" is how this board lost a day already.
      // MUST READ 0.
      if (ymw_ev && ymw_hold && dbg_ym_drop != 16'hFFFF)
        dbg_ym_drop <= dbg_ym_drop + 16'd1;
    end
  end

  // jt51's `dout` is unconditional -- `assign dout = {busy,5'h0,flag_B,flag_A}`
  // at jt51.v:273, with no cs_n in it -- so reads need no select and this can
  // be a write-only strobe.
  wire       ym_cs_n = ~ymw_act;

  jt51 u_jt51 (
      .rst    (snd_rst),
      .clk    (clk),
      .cen    (ym_cen),
      .cen_p1 (ym_cen_p1),
      .cs_n   (ym_cs_n),
      .wr_n   (~ymw_act),
      .a0     (ymw_a0),
      .din    (ymw_din),
      .dout   (ym_dout),
      .ct1    (),
      .ct2    (),
      .irq_n  (ym_irq_n),
      .sample (),
      .left   (),
      .right  (),
      .xleft  (ym_l),
      .xright (ym_r)
  );

  assign int_n = ym_irq_n;

  // ---------------------------------------------------------------------
  // OKI M6295
  //
  // ss = 1 is pin 7 HIGH, which the driver header records as measured on the
  // PCB.  It selects the /132 divider, so at 1.6869 MHz the sample rate is
  // about 12.8 kHz.
  //
  // The bank bit at E800 picks which 256 K half of the 512 K sample ROM the
  // chip's 18-bit address lands in.
  // ---------------------------------------------------------------------
  reg oki_bank;
  always @(posedge clk) begin
    if (rst)                             oki_bank <= 1'b0;
    else if (sel_bank && mem_wr)         oki_bank <= z80_do[0];
  end

  wire [17:0] oki_rom_a;
  wire [7:0]  oki_dout;
  wire signed [13:0] oki_snd;
  wire [7:0]  oki_rom_d;
  // `rom_ok` MEANS "rom_data is right for the address on rom_addr NOW", so it
  // is combinational.  It was a register, and a register is one clock late:
  // on the clock oki_rom_a moved to a different word, oki_rom_ok was still 1
  // while oki_rom_d had already switched to the new address's byte lane of
  // the OLD word.  jt6295_rom waits two clocks after its address settles and
  // then trusts rom_ok (jt6295_rom.v, `wait2==2'b11 && !new_addr`), which
  // overlaps that window.
  //
  // Measured 2026-09-04: worst |delta| a frame reached 2634 and 2984 against
  // MAME's 1888, with 2 and 6 jumps over 2048 on those frames -- audible as
  // the noise reported once the samples started playing at all.
  //
  // `pcm_seen` is the word we hold and is only written at an acknowledge, so
  // comparing it with the live address says exactly what the contract asks
  // and cannot be stale.  It also drops the moment the address moves, which
  // is what the register could not do.
  wire        oki_rom_ok = (pcm_word == pcm_seen);

  jt6295 #(.INTERPOL(0)) u_jt6295 (
      .rst      (snd_rst),
      .clk      (clk),
      .cen      (oki_cen),
      .ss       (1'b1),                     // pin 7 HIGH, HW_CONFIRMED
      .wrn      (~(sel_oki & mem_wr)),
      .din      (z80_do),
      .dout     (oki_dout),
      .rom_addr (oki_rom_a),
      .rom_data (oki_rom_d),
      .rom_ok   (oki_rom_ok),
      .sound    (oki_snd),
      .sample   ()
  );

  // Sample fetch.  The chip asks for a byte; SDRAM gives a word, so the lane
  // is selected the same way the program fetch does it.
  wire [24:0] pcm_word = oki_base_w + {7'd0, oki_bank, oki_rom_a[17:1]};
  reg  [24:0] pcm_seen;
  reg         pcm_busy;
  reg  [15:0] pcm_hold;      // the WORD we hold; the byte is picked live

  // THE BYTE FOLLOWS THE ADDRESS, IT IS NOT LATCHED AT THE FETCH.
  //
  // `pcm_word` drops bit 0, so the two bytes of one word are the SAME word
  // and moving between them does not refetch -- which is right, and was the
  // point of comparing words rather than bytes.  But `oki_rom_d` was only
  // written at `pcm_ack`, so after that move it still held the OTHER byte
  // while `oki_rom_ok` stayed HIGH.  jt6295 was handed the wrong byte and
  // told it was good.
  //
  // The phrase table is read as CONSECUTIVE BYTES to build a sample's start
  // and stop address (jt6295_ctrl.v), so a stale second byte does not make a
  // sample sound slightly wrong -- it sends the chip somewhere else in the
  // ROM entirely.  Effects firing at the wrong moment on a menu and nothing
  // at all in a stage is what that looks like.
  //
  // Picking the byte from the held word costs nothing and cannot be stale:
  // while the word is valid, both of its bytes are.
  assign oki_rom_d = oki_rom_a[0] ? pcm_hold[7:0] : pcm_hold[15:8];

  assign pcm_addr = pcm_word;
  assign pcm_req  = pcm_busy;

  always @(posedge clk) begin
    if (rst | snd_rst) begin
      pcm_busy      <= 1'b0;
      pcm_hold      <= 16'd0;
      pcm_seen      <= 25'h1FFFFFF;
      dbg_pcm_fetch <= 16'd0;
    end else begin
      if (!pcm_busy) begin
        // Follow the chip's address, not a strobe: jt6295 has no handshake
        // because the real chip owns its ROM pins.  Refetch only when the
        // WORD changes, which is what stops the "seventy times too often"
        // failure Power Spikes hit on its ADPCM fetcher.
        if (pcm_word != pcm_seen) begin
          pcm_busy   <= 1'b1;
        end
      end else if (pcm_ack) begin
        pcm_hold      <= pcm_data;
        // TWO READINGS OF ONE FACT (project CLAUDE.md 1.4).
        //
        // Everything else about this path checks out: the chip, the ROM
        // image, the fetcher, the cache and the latency all pass in
        // simulation (sim/tb_oki*.sv -- 98 % of output samples non-zero),
        // and on hardware the command chain matches MAME to the ratio.  The
        // one thing never read back is what the chip actually RECEIVES.
        //
        // Word 4 of the OKI region is bytes 8 and 9, the first two of phrase
        // 1's table entry, and the ROM says they are 00 04.  Reading 0004
        // here means the data arriving is right and the fault is elsewhere
        // again; anything else means it is this.
        // EVERY read, not one address.
        //
        // The first cut latched only the word at OKI offset 4 -- phrase 1's
        // table entry -- and read 0000 on hardware.  Which proves nothing:
        // 0000 is also the reset value, so "the data is zero" and "that
        // address was never asked for" give the SAME ANSWER.  That is the
        // trap this project keeps walking into (A16, A20, and row 30's
        // `oki_cen & ~oki_rom_ok` earlier today), and it cost a bitstream.
        //
        // Latching every acknowledged word cannot be ambiguous.  The OKI
        // reads constantly -- tens of thousands of words a second, measured
        // -- so a value that sits at 0000 means it is genuinely being handed
        // zeros, and anything that moves means real data is arriving.
        dbg_pcm_fetch <= pcm_data;
        pcm_seen      <= pcm_word;
        pcm_busy      <= 1'b0;
        // (was a free-running fetch count; row 37 is the probe now)
      end
    end
  end

  // ---------------------------------------------------------------------
  // Read mux
  // ---------------------------------------------------------------------
  always @(*) begin
    z80_di = 8'hFF;
    if      (sel_rom)  z80_di = rom_byte;
    else if (wram_sel) z80_di = wram_q;
    else if (sel_ym)   z80_di = ym_dout;
    else if (sel_oki)  z80_di = oki_dout;
    else if (sel_lat)  z80_di = latch_d;
  end

  // ---------------------------------------------------------------------
  // Mix.
  //
  // MAME routes YM2151 channel 0 left and channel 1 right at 0.50 each, and
  // the M6295 to BOTH at 0.50 -- EQUAL.  So this is genuinely stereo and must
  // not be summed to mono, and the two streams have to arrive on the same
  // scale before they are added.
  //
  // `oki_snd` is 14-bit signed and `ym_l` is 16-bit signed, so the OKI needs
  // TWO bits, not one.  jt6295 says so itself: its only statement about its
  // own full scale is jt6295.v:173, where it writes a 16-bit raw dump as
  //
  //     wire signed [15:0] snd_log = { sound, 2'b0 };      // << 2
  //
  // This shifted by ONE, which put the OKI 6 dB below the FM -- the music
  // played and the samples under it were half as loud as the board makes
  // them.  Reported from play on 2026-09-04 as "the sound effects seem to be
  // missing", which is what a 6 dB deficit under a full FM mix sounds like.
  //
  // ---------------------------------------------------------------------
  // AND THEN THE WHOLE THING IS TWICE AS LOUD, BY MEASUREMENT.
  //
  // The `>>1` that used to be here is what MAME's two 0.50 routes mean
  // arithmetically, and it was faithful.  It also threw away 6 dB that this
  // board has no reason to throw away, and the person playing said so:
  // "소리도 작어".
  //
  // The headroom is measured, not assumed.  MAME rendered over 45 s of play,
  // per video frame, peaks at 5981 of 32767 -- EIGHTEEN PER CENT of full
  // scale -- with a median of 2363.  Doubling puts the loudest frame this
  // game is known to produce at 36 %, so the saturation below is reached by
  // nothing the game does; it is there because two chips at once CAN reach
  // +-65535 in principle and a sum that wraps is a far worse noise than a
  // sum that clips.
  //
  // The relative gain is untouched: MAME routes YM and OKI at 0.50 each, so
  // they stay 1:1 and only the pair moves.  That is a volume control, which
  // is what the PCB's two MB3615 amplifiers are.
  //
  // The sibling core is the reason to think 16 bits is the right target at
  // all: ps_sound wires `snd_l` straight to jt10's `snd_left` with no shift
  // of any kind, and Power Spikes is the verified-on-hardware baseline in
  // this factory.  Shadow Force was the only core here running 6 dB down.
  //
  // NOTE FOR EVERY COMPARISON AFTER THIS COMMIT: row 29 now reads on a
  // DOUBLED scale.  MAME's per-frame peak of median 2363 / p90 4073 / max
  // 5981 becomes median 4726 / p90 8146 / max 11962 against this row.  Rows
  // 39 and 40 are unchanged -- they were always measured before the shift.
  // ---------------------------------------------------------------------
  // 1 sign bit + 14 + 2 = 17, matching the target.  Two sign bits made it 18
  // and Verilog dropped the top one -- which is the sign.
  // THE OKI SHIFT IS <<4, AND IT COMES OUT OF THE TWO SOURCES, NOT AN EAR.
  //
  //   jt6295_adpcm.v:141   sound <= mul_VI[16:5];
  //     snd is 12-bit signed and gain_lut[0] is 32, so a full-scale channel
  //     leaves this at +-2048.  jt6295_acc sums four of them into +-8192.
  //
  //   MAME okim6295.cpp:352
  //     stream.add_int(0, sampindex, m_adpcm.clock(nibble) * m_volume, 2048);
  //     clock() is +-2048 and m_volume is 0..1.0, NORMALISED BY 2048 -- so a
  //     full-scale channel is +-1.0, which is +-32768 on a 16-bit rail, and
  //     four of them reach +-4.0 and clip at the speaker.
  //
  // 32768 / 2048 = 16.  The shift was <<2 and had been four times short since
  // the chip was wired up.
  wire signed [18:0] oki_x1 = {oki_snd[13], oki_snd, 4'b0};
  wire signed [21:0] oki_e  = {{3{oki_x1[18]}}, oki_x1};

  // SFX volume -- the OKI only, applied BEFORE the sum so the FM is untouched.
  wire signed [21:0] oki_g =
      (cfg_oki_gain == 2'd0) ? oki_e :
      (cfg_oki_gain == 2'd1) ? (oki_e <<< 1) :
      (cfg_oki_gain == 2'd2) ? (oki_e + (oki_e <<< 1)) :
                               (oki_e <<< 2);

  // EMULATION_DERIVED  (accuracy axis -- root CLAUDE.md 1.6.  Purity is
  // PURE_RTL and this does not block release; only being UNMARKED would.)
  //
  // The YM:OKI RELATIVE gain below is 1:1 because MAME routes both chips at
  // 0.50 (shadfrce.cpp:830-835), and the <<4 above lands the OKI on MAME's
  // scale.  That makes this mix match the EMULATOR.  The PCB mixes in the
  // analogue domain through two MB3615 amplifiers whose resistor network has
  // never been read, so the real ratio is NOT VERIFIED and is not claimed.
  //
  // TODO(HARDWAREIZE): read the MB3615 summing network on the PCB -- the
  // resistors into each amplifier's inverting input give the true YM:OKI
  // ratio directly.  Until then this is the emulator's ratio, deliberately.
  wire signed [21:0] ym_e_l = {{6{ym_l[15]}}, ym_l};
  wire signed [21:0] ym_e_r = {{6{ym_r[15]}}, ym_r};

  // BGM volume -- the FM only, the mirror of the SFX dial above.
  //
  // THIS REPLACED A MASTER "Mix gain" AND THE REPLACEMENT IS THE POINT.  The
  // old dial scaled BOTH sources, so the only way to hear more of the samples
  // was to raise the OKI dial AND the master, and that combination is what
  // put the mix four times over MAME and against the clamp (DEBUG_LOG A54).
  // A master above x1 can only ever move the sum toward `sat16`; a per-source
  // pair moves the BALANCE, which is the thing anyone actually wants to
  // change.  Both default to x1, and x1/x1 is MAME exactly.
  wire signed [21:0] ym_g_l =
      (cfg_ym_gain == 2'd0) ? ym_e_l :
      (cfg_ym_gain == 2'd1) ? (ym_e_l <<< 1) :
      (cfg_ym_gain == 2'd2) ? (ym_e_l + (ym_e_l <<< 1)) :
                              (ym_e_l <<< 2);
  wire signed [21:0] ym_g_r =
      (cfg_ym_gain == 2'd0) ? ym_e_r :
      (cfg_ym_gain == 2'd1) ? (ym_e_r <<< 1) :
      (cfg_ym_gain == 2'd2) ? (ym_e_r + (ym_e_r <<< 1)) :
                              (ym_e_r <<< 2);

  wire signed [22:0] mix_l = {ym_g_l[21], ym_g_l} + {oki_g[21], oki_g};
  wire signed [22:0] mix_r = {ym_g_r[21], ym_g_r} + {oki_g[21], oki_g};

  // ...then halve, because MAME routes both chips at 0.50 and sums: its
  // output is (ym + oki<<4)/2, and that is what x1/x1 produces here.
  //
  // There is no master gain any more.  The one that was here had no setting
  // below the raw sum, which is twice MAME, and reaching a listenable balance
  // through it meant multiplying both sources -- reported by ear as "스피커에
  // 물 젖은 것 같은 소리, 먹먹한 소리", a mix spending its loud passages
  // against the clamp.  Measured on hardware afterwards (A58): at x1/x1 the
  // worst |mix| before the clamp is 11 955 of 32 767 and nothing is clamped.
  wire signed [24:0] mixg_l = {{3{mix_l[22]}}, mix_l[22:1]};
  wire signed [24:0] mixg_r = {{3{mix_r[22]}}, mix_r[22:1]};

  // `-16'sd32768` is what this said, and Quartus was right to complain
  // (10259, constant value overflow): 16'sd32768 does not fit in a 16-bit
  // signed literal, it wraps to 0x8000, and negating 0x8000 gives 0x8000
  // again -- so the RESULT was correct and the expression was nonsense.
  // 16'sh8000 is the same number said properly, and it is the only
  // project-owned warning this build carried.
  function automatic signed [15:0] sat16(input signed [24:0] v);
    sat16 = (v >  25'sd32767) ? 16'sd32767 :
            (v < -25'sd32768) ? 16'sh8000  : v[15:0];
  endfunction

  // TWICE MAME's arithmetic.  It was x4 for one build and that was WRONG, and
  // the way it was wrong is worth keeping:
  //
  //   x4 was sized on 45 s of PLAY, where MAME peaks at 5981 of 32767 -- 18 %
  //   -- so quadrupling looked like it left 20 % headroom and measured ZERO
  //   saturating samples.  Then 185 s of pure ATTRACT was rendered, and
  //   attract peaks at 19728.  SIXTY PER CENT.  Three and a third times
  //   louder than the passage the gain was chosen on.
  //
  //     gain   attract peak    saturating samples in 185 s
  //       x1        19728              0
  //       x2        clipped           80        (0.0002 %)
  //       x3        clipped         4196        (0.05 %)
  //       x4        clipped        21160        (0.24 %)
  //
  //   0.24 % of samples hard-clipped is not a rounding error, it is harmonic
  //   distortion across the whole attract, and it was reported by ear the
  //   morning after as "노이즈 엄청 심해".
  //
  // THE MEASUREMENT WAS RIGHT AND THE WINDOW WAS WRONG.  Play is not this
  // game's loud case; attract is, and nobody had rendered it because the
  // scripts all coin up at 20 s to reach the game.  The same mistake as
  // MAX_ACT measured on the attract loop, in the other direction.
  //
  // x2 keeps 80 samples of clipping in 185 s, which is 0.0002 % and inaudible,
  // and puts attract at the full 16-bit range with play at 37 %.  That is the
  // most gain this game supports.
  //
  // Row 29 reads on the x2 scale: MAME's per-frame attract peak of median
  // 12184 / p90 28132 becomes median 6092 / p90 14066 against it, and play's
  // median 2363 becomes 4726.  Rows 39 and 40 are measured ahead of the gain
  // and do not move.
  assign snd_l = sat16(mixg_l);
  assign snd_r = sat16(mixg_r);

  // ---- rows 46 and 47: headroom, measured here rather than in MAME -------
  wire clip_l = (mixg_l >  25'sd32767) || (mixg_l < -25'sd32768);
  wire clip_r = (mixg_r >  25'sd32767) || (mixg_r < -25'sd32768);
  wire [24:0] mag_l = mixg_l[24] ? (~mixg_l + 25'd1) : mixg_l;
  wire [24:0] mag_r = mixg_r[24] ? (~mixg_r + 25'd1) : mixg_r;
  wire [24:0] mag   = (mag_l > mag_r) ? mag_l : mag_r;
  wire [15:0] mag16 = |mag[24:16] ? 16'hFFFF : mag[15:0];   // saturate to say "over"

  // ---- row 48: OKI voices held -----------------------------------------
  // jt6295's own status byte is {4'hf, busy | start}, which is what the Z80
  // reads at D800 -- so this is the chip's answer, not a guess from outside.
  wire [3:0] oki_busy = oki_dout[3:0];
  reg  [3:0] vmax_acc;
  wire [2:0] vpop = {2'd0, oki_busy[0]} + {2'd0, oki_busy[1]}
                  + {2'd0, oki_busy[2]} + {2'd0, oki_busy[3]};
  always @(posedge clk) begin
    if (rst) begin
      vmax_acc <= 4'd0;  dbg_oki_voice <= 16'd0;
    end else begin
      if ({1'b0, vpop} > vmax_acc) vmax_acc <= {1'b0, vpop};
      if (frame) begin
        dbg_oki_voice <= {4'd0, vmax_acc, 4'd0, oki_busy};
        vmax_acc      <= {1'b0, vpop};
      end
    end
  end

  reg [15:0] clip_acc, premax_acc;
  always @(posedge clk) begin
    if (rst) begin
      clip_acc <= 16'd0;  premax_acc <= 16'd0;
      dbg_clip <= 16'd0;  dbg_premax <= 16'd0;
    end else begin
      if ((clip_l | clip_r) && clip_acc != 16'hFFFF) clip_acc <= clip_acc + 16'd1;
      if (mag16 > premax_acc) premax_acc <= mag16;
      if (frame) begin
        dbg_clip   <= clip_acc;
        dbg_premax <= premax_acc;
        clip_acc   <= 16'd0;
        premax_acc <= 16'd0;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Instruments.  Each failure gets a different reading rather than every
  // row going to zero at once -- the property that made Power Spikes' sound
  // overlay usable.
  // ---------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst) begin
      dbg_z80_cyc   <= 16'd0;
      dbg_ym_wr     <= 16'd0;
      dbg_z80_stall <= 16'd0;
      dbg_rom_w0    <= 16'd0;  oki_writes <= 8'd0;  oki_starts <= 8'd0;
      oki_wr_acc    <= 8'd0;   oki_st_acc <= 8'd0;  oki_w2 <= 1'b0;
    end else begin
      if (mem_rd && cen_p)                  dbg_z80_cyc <= dbg_z80_cyc + 16'd1;
      if (sel_ym && mem_wr && cen_p)        dbg_ym_wr   <= dbg_ym_wr + 16'd1;
      if (stall && dbg_z80_stall != 16'hFFFF)
                                            dbg_z80_stall <= dbg_z80_stall + 16'd1;
      // word 0 of the sound ROM, as it comes back from SDRAM.  The real ROM
      // starts F3 ED = DI ; so anything else means the download missed this
      // region and the Z80 is executing whatever is there instead.
      // The M6295 takes TWO writes: 0x80|phrase, then channel<<4 | volume.
      // A start is the SECOND of the pair with a non-zero channel nibble --
      // the same test tools/mame_sfx_who.lua uses, so the two numbers are
      // comparable.
      if (sel_oki && mem_wr && cen_p) begin
        if (oki_w2) begin
          oki_w2 <= 1'b0;
          if (|z80_do[7:4] && oki_st_acc != 8'hFF) oki_st_acc <= oki_st_acc + 8'd1;
        end else if (z80_do[7]) begin
          oki_w2 <= 1'b1;
        end
        if (oki_wr_acc != 8'hFF) oki_wr_acc <= oki_wr_acc + 8'd1;
      end
      if (frame) begin
        oki_writes <= oki_wr_acc;  oki_wr_acc <= 8'd0;
        oki_starts <= oki_st_acc;  oki_st_acc <= 8'd0;
      end
      dbg_rom_w0 <= {oki_writes, oki_starts};
    end
  end

  assign dbg_state = {halt_n, pending, nmi_n, int_n, oki_bank, cache_v,
                      fetching, pcm_busy};

  // ---------------------------------------------------------------------
  // The complaint itself: sample discontinuities, per frame.
  //
  // Sampled EVERY CLOCK, and the rate matters more than it looks.
  //
  // MAME's threshold was derived from a 48 kHz render.  Sampling the mix more
  // SLOWLY than that would put more signal between consecutive samples and
  // inflate every delta, so a 12.8 kHz sample at the OKI's own tick -- the
  // obvious choice, since that is the slowest thing feeding the mix -- would
  // manufacture jumps over 2048 out of ordinary music and the row would read
  // "broken" on a healthy board.
  //
  // Sampling FASTER than the signal changes cannot do that.  A held value
  // gives a delta of zero however often it is read, and a real step still
  // shows its full magnitude exactly once.  So every clock is both the
  // cheapest and the only conservative choice, and 2048 keeps the meaning it
  // has in MAME's own audio.
  //
  // `dbg_snd_maxdel` is the second reading of the same fact (project
  // CLAUDE.md 1.4): a jump COUNT of zero with a maximum of 3000 would mean
  // the threshold comparison is broken, and a count without a magnitude
  // cannot tell "one bad sample" from "the channel is inverted".
  // ---------------------------------------------------------------------
  reg signed [15:0] snd_l_d;
  wire signed [16:0] sdelta = {snd_l[15], snd_l} - {snd_l_d[15], snd_l_d};
  wire       [15:0] sabs   = sdelta[16] ? (~sdelta[15:0] + 16'd1) : sdelta[15:0];

  // "Late" means the chip was CLOCKED without the byte it asked for, not that
  // a fetch was in flight.
  //
  // The first cut counted `pcm_busy & ~oki_rom_ok`, which is high for the
  // whole duration of every fetch and is therefore nonzero on a perfectly
  // healthy board -- it measured fetch latency and called it lateness.  On
  // hardware it duly read FFFF on all eight frames and said nothing at all.
  //
  // jt6295 advances only on `oki_cen`, so the clocks that can hurt are the
  // ones where `oki_cen` fires and `oki_rom_ok` is still low.  That is a
  // number whose zero means something.
  wire pcm_is_late = oki_cen & ~oki_rom_ok;

  // ---- rows 44 and 45: the duration row 30 could not give ----------------
  // ADPCM_WINDOW is what jt6295_rom assumes the ROM answers within.  It is a
  // localparam and not a dial on purpose: a runtime compare here would sit on
  // the same path the arbiter switch was removed from (sf_top, 936257e).
  localparam [15:0] ADPCM_WINDOW = 16'd265;
  reg [15:0] lat_cnt, latmax_acc, over_acc;
  always @(posedge clk) begin
    if (rst) begin
      lat_cnt <= 16'd0;  latmax_acc <= 16'd0;  over_acc <= 16'd0;
      dbg_pcm_lat <= 16'd0;  dbg_pcm_over <= 16'd0;
    end else begin
      // counts while a fetch is outstanding, cleared between them
      if (!pcm_busy)                  lat_cnt <= 16'd0;
      else if (lat_cnt != 16'hFFFF)   lat_cnt <= lat_cnt + 16'd1;

      if (pcm_busy && pcm_ack) begin
        if (lat_cnt > latmax_acc) latmax_acc <= lat_cnt;
        if (lat_cnt > ADPCM_WINDOW && over_acc != 16'hFFFF)
          over_acc <= over_acc + 16'd1;
      end

      if (frame) begin
        dbg_pcm_lat  <= latmax_acc;
        dbg_pcm_over <= over_acc;
        latmax_acc   <= 16'd0;
        over_acc     <= 16'd0;
      end
    end
  end

  wire [15:0] snd_abs = snd_l[15] ? (~{snd_l} + 16'd1) : {snd_l};

  // ACCUMULATE into _acc, PUBLISH on the frame pulse.  Zeroing the output
  // itself at the frame boundary would leave the overlay -- which is drawn
  // during the frame, not at its edge -- reading a count that is part way
  // through accumulating.  That is the same shape as A20, where a counter was
  // read at a moment it did not describe and gave the same answer for
  // opposite states.
  // PER FRAME, not free-running.  The first cut of these was a pair of
  // saturating 8-bit free-running counters, and both pinned at FF within
  // seconds of boot -- the overlay read 255/255 for fourteen straight frames
  // and could not say whether anything was happening NOW.  A counter that
  // saturates is a counter that stops being an instrument, which is the same
  // shape as the wrapping ones A11 is about.
  //
  // These accumulate and publish on the frame pulse like every other row
  // here, so the overlay reads what THIS frame did.
  reg [7:0]  oki_wr_acc, oki_st_acc;
  reg [7:0]  oki_writes, oki_starts;   // published, per frame
  reg        oki_w2;                   // the M6295's second byte is due
  reg [15:0] jumps_acc, maxdel_acc, late_acc, stall_acc, peak_acc, z80clk_acc;

  // -- per-source peaks ------------------------------------------------
  // Both on the scale the source ENTERS THE MIX on, so they are directly
  // comparable with each other and with row 29.  |-32768| is 32768, which
  // does not fit in 16 SIGNED bits -- these are read as UNSIGNED, and
  // 16'h8000 is the correct 32768 there.
  wire [15:0] ym_abs  = ym_l[15] ? (~{ym_l} + 16'd1) : {ym_l};
  wire [13:0] oki_a14 = oki_snd[13] ? (~{oki_snd} + 14'd1) : {oki_snd};
  wire [15:0] oki_abs = {oki_a14, 2'b0};          // the mix's own << 2

  // -- what the game ASKED for -----------------------------------------
  // The YM2151 takes an address byte at a0=0 and a data byte at a0=1, so a
  // KON is a write of 0x08 followed by a write of {0, slots[3:0], ch[2:0]}.
  // A slot mask of zero is a key OFF and must not light the channel bit --
  // counting those would make a frame that silences everything look like a
  // frame that started everything.
  //
  // Counted on the RISING EDGE of the select.  Holding mem_wr across two or
  // three cen_p pulses is what a Z80 write cycle DOES, so a cen_p-gated
  // count is a count of T-states that happened to overlap a write.
  reg        ym_sel_d;
  wire       ym_wr_e = (sel_ym & mem_wr) & ~ym_sel_d;
  reg [7:0]  ym_reg;                    // our shadow of jt51's reg_sel
  wire       kon_wr = ym_wr_e & z80_a[0] & (ym_reg == 8'h08);
  // HELD, not accumulated: this must survive the frame boundary, because a
  // note held across ten frames is one key-on and ten frames of sound.
  reg [7:0]  kon_held;
  reg [7:0]  kon_cnt_acc;
  reg [15:0] ympk_acc, okipk_acc, ymwr_acc;

  always @(posedge clk) begin
    if (rst) begin
      snd_l_d         <= 16'sd0;
      jumps_acc <= 16'd0; maxdel_acc  <= 16'd0;
      late_acc  <= 16'd0; stall_acc   <= 16'd0;
      peak_acc  <= 16'd0; z80clk_acc  <= 16'd0;
      dbg_snd_jumps   <= 16'd0;
      dbg_snd_maxdel  <= 16'd0;
      dbg_pcm_late    <= 16'd0;
      dbg_z80_stall_f <= 16'd0;
      dbg_snd_peak    <= 16'd0;
      dbg_z80_clk     <= 16'd0;
      ym_sel_d <= 1'b0;   ym_reg    <= 8'd0;
      kon_held     <= 8'd0;  kon_cnt_acc <= 8'd0;
      ympk_acc <= 16'd0;  okipk_acc <= 16'd0;  ymwr_acc <= 16'd0;
      dbg_ym_peak  <= 16'd0;  dbg_oki_peak <= 16'd0;
      dbg_ym_kon   <= 16'd0;  dbg_ym_wr_e  <= 16'd0;
    end else begin
      snd_l_d  <= snd_l;
      ym_sel_d <= sel_ym & mem_wr;

      if (ym_wr_e) begin
        if (!z80_a[0]) ym_reg <= z80_do;
        if (ymwr_acc != 16'hFFFF) ymwr_acc <= ymwr_acc + 16'd1;
      end
      if (kon_wr) begin
        // slot mask non-zero = key ON, zero = key OFF.  Both are register 08
        // writes, and treating an OFF as an ON would make the frame that
        // silences the music look like the frame that started it.
        kon_held[z80_do[2:0]] <= |z80_do[6:3];
        if (kon_cnt_acc != 8'hFF) kon_cnt_acc <= kon_cnt_acc + 8'd1;
      end
      if (ym_abs  > ympk_acc)  ympk_acc  <= ym_abs;
      if (oki_abs > okipk_acc) okipk_acc <= oki_abs;

      if (sabs > 16'd2048 && jumps_acc != 16'hFFFF)
        jumps_acc <= jumps_acc + 16'd1;
      if (sabs > maxdel_acc) maxdel_acc <= sabs;
      if (pcm_is_late && late_acc   != 16'hFFFF) late_acc   <= late_acc   + 16'd1;
      if (stall       && stall_acc  != 16'hFFFF) stall_acc  <= stall_acc  + 16'd1;
      if (cen_p       && z80clk_acc != 16'hFFFF) z80clk_acc <= z80clk_acc + 16'd1;
      if (snd_abs > peak_acc) peak_acc <= snd_abs;

      if (frame) begin
        dbg_snd_jumps   <= jumps_acc;
        dbg_snd_maxdel  <= maxdel_acc;
        dbg_pcm_late    <= late_acc;
        dbg_z80_stall_f <= stall_acc;
        dbg_snd_peak    <= peak_acc;
        dbg_z80_clk     <= z80clk_acc;
        dbg_ym_peak     <= ympk_acc;
        dbg_oki_peak    <= okipk_acc;
        dbg_ym_kon      <= {kon_held, kon_cnt_acc};
        dbg_ym_wr_e     <= ymwr_acc;
        jumps_acc <= 16'd0; maxdel_acc  <= 16'd0;
        late_acc  <= 16'd0; stall_acc   <= 16'd0;
        peak_acc  <= 16'd0; z80clk_acc  <= 16'd0;
        ympk_acc  <= 16'd0; okipk_acc   <= 16'd0;
        ymwr_acc  <= 16'd0;
        kon_cnt_acc <= 8'd0;      // kon_held is NOT cleared -- it is a state
      end
    end
  end

endmodule

`default_nettype wire
