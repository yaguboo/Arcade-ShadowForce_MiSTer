//============================================================================
//  Shadow Force -- sprite engine
//
//  Scanline renderer: while line L is displayed, line L+1 is built into a
//  double-buffered line buffer.  sf_top copies sprite RAM at vblank, so this
//  reads a snapshot the CPU cannot disturb mid-frame.
//
//  ---- the entry, from MAME ------------------------------------------------
//
//  `shadfrce.cpp:317-361`, every field cross-checked in docs/MAME_AUDIT.md
//  section 4b.  512 entries, 8 words each:
//
//      ypos    = 0x100 - ((w0[1:0] << 8) | w1[7:0])   subtracted, not offset
//      xpos    = ((w4[0]  << 8) | w5[7:0]) + 1        the +1 is real
//      tile    = (w2[7:0] << 8) | w3[7:0]
//      height  = w0[7:5] + 1                          1..8 tiles
//      enable  = w0[2]
//      flipx   = w0[4]        flipy = w0[3]
//      pal     = w4 & 0x3e,  then if (pal & 0x20) pal ^= 0x60
//      pri     = w4[6]        hidden where bg0 drew
//
//  Tile n is drawn at `ypos - n*16 - 16`, so **tile 0 is the BOTTOM one** and
//  they stack upward.  That -16 is the origin convention: the coordinate names
//  the bottom of the first tile.  Backwards puts every multi-tile sprite one
//  tile out, and only tall ones show it.
//
//  ---- the ROM decode, in word addresses ----------------------------------
//
//      sp16x16x5 = { 16,16, RGN_FRAC(1,5), 5,
//        { RGN_FRAC(4,5), RGN_FRAC(3,5), RGN_FRAC(2,5), RGN_FRAC(1,5),
//          RGN_FRAC(0,5) },
//        { STEP8(0,1), STEP8(16*8,1) }, { STEP16(0,8) }, 16*16 }
//
//  MAME's plane list is MSB first, so entry 0 -- RGN_FRAC(4,5) -- is pen bit
//  4.  Turned round: **fifth f supplies pen bit f.**
//
//      byte(f, half) = f*0x200000 + tile*32 + half*16 + y
//      word          = f*0x100000 + tile*16 + half*8  + y[3:1]
//      which byte    = y[0]        -- even byte is the HIGH half, big-endian
//
//  Ten reads a tile row, one byte used from each.  The other byte is the next
//  scanline of the same tile -- the waste fg has too (DEBUG_LOG A9).  Not
//  exploited yet; correct and measured first.
//
//  ---- priority: 0 -> 511 with overwrite is exact ------------------------
//
//  `prio_transpen` sets `pmask |= 1 << 31` (emu/drawgfx.cpp:933) before its
//  pixel loop, so the FIRST sprite to touch a pixel blocks every later one,
//  and MAME's loop runs 511 down to 0.  **Entry 511 is on top.**  Walking
//  0 -> 511 and overwriting gives the identical picture in one pass.
//
//  A sprite hidden behind bg0 STILL CLAIMS its pixel -- MAME writes
//  `PRIORITY = 31` on the not-drawn path too -- so the buffer carries the
//  priority bit and sf_video applies the bg0 test at mix time.  Skipping the
//  write would let a lower entry show through a hole the hardware lacks.
//
//  ---- why the list is walked once a FRAME, not once a line --------------
//
//  It used to be walked every line: six clocks an entry -- address, two of RAM
//  latency, latch, test, advance -- which is 3072 of a line's 3584 clocks,
//  plus 512 more to clear the buffer.  The whole line, before a single sprite
//  byte was fetched.  On hardware the walk was simply cut off partway and only
//  low-numbered entries ever drew, which is exactly what the screen showed
//  (DEBUG_LOG A19).
//
//  Now the walk happens ONCE PER FRAME in vertical blanking, and only what the
//  per-line test needs -- {index, ypos, height} for the ENABLED entries -- is
//  kept.  Vblank is 32 lines, 114,688 clocks; the prescan needs about 1,500.
//  Per line the engine compares that short list instead, one entry a clock: in
//  this game's attract 27 of 512 are enabled.
//
//  **MAME does the full walk every frame and never notices, because it has no
//  scanline budget at all.**  That is the one thing comparing against MAME
//  cannot show, and it is why the algorithm was pixel-exact against MAME
//  (MAME_AUDIT section 8) while the picture was still wrong.
//
//  ---- coordinates --------------------------------------------------------
//
//  Both axes are 9-bit and wrap at 512, which is exactly MAME's four draws at
//  `x`, `x-0x200`, `y+0x200` and both, without drawing anything four times.
//  The ypos field is ten bits and its top one is worth 512, so it vanishes in
//  that modulus -- dropped explicitly, because a silent width warning is how
//  L2 hid a real out-of-range index.
//============================================================================
`default_nettype none

module sf_sprite #(
    parameter int H_VISIBLE = 320,
    parameter int V_VISIBLE = 240,
    parameter int V_TOTAL   = 272,
    // How many enabled entries a frame may carry.
    //
    // THIS WAS 128, AND 128 WAS MEASURED ON THE ATTRACT LOOP.  The comment
    // here said 128 was "four times what this game's attract uses" -- true of
    // the attract loop and false of the game.  MAME, coined up and played,
    // reaches **156** enabled entries and wants more than 128 on **1.89 %**
    // of frames (tools/mame_spr_enabled_play.lua, 7,353 frames).
    //
    // Everything past the cap was dropped in silence, and it is the WRONG END
    // that gets dropped.  MAME walks entry 511 DOWN TO 0 with first-write-
    // wins, so the high-numbered entries are the ones drawn ON TOP; this
    // prescan fills from entry 0 upward and stops, so what it throws away is
    // exactly what should have been in front.  Reported from play on
    // 2026-09-04: the character-select portrait misplaced, its frame absent,
    // and a special move's name never appearing -- all of them overlay art.
    //
    // 256 covers the measured 156 with two thirds again to spare.  Not 512:
    // the per-line walk costs one clock an entry out of 3,584 and the blit
    // budget is MAX_ACT*16, so 512 would put both past a line.
    parameter int MAX_ACT   = 256
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,

    input  wire [8:0]  hcnt,
    input  wire [8:0]  vcnt,

    // Flip screen.  sf_video mirrors `vcnt` for every layer before it arrives,
    // and mirrors `hcnt` for the tile layers -- but not for this one, because
    // here `hcnt` is TWO things: the source column being read out, and the
    // beam progress the erase trails.  Only the first may be mirrored.
    input  wire        flip,
    input  wire        line_start,
    input  wire        copy_done,       // sprite RAM copy finished, buffer valid

    // --- sprite RAM: the vblank-copied buffer, read only -------------------
    output reg  [11:0] spr_addr,
    input  wire [15:0] spr_data,

    // --- sprite ROM, through the arbiter -----------------------------------
    output reg  [24:0] rom_addr,
    input  wire [15:0] rom_data,
    output reg         rom_req,
    // D24.  "My next word is the same fetch, and its address is already up."
    // D15's contract, which bg and fg have spoken since it was written.  The
    // sprite could not before D20: its five words were five planes a megabyte
    // apart, so holding the grant bought nothing and A33 measured exactly
    // that -- 1.5 %.  D20 made them five CONSECUTIVE words in one row, and
    // that measurement went stale the moment it did.  The next address is now
    // rom_addr + 1.
    output wire        rom_hold,
    input  wire        rom_ack,
    input  wire [24:0] spr_base_w,      // SPRITES_BASE_W, from sf_rommap.svh

    // --- pixel out, for the current hcnt -----------------------------------
    output wire [13:0] pal_index,
    output wire        opaque,
    output wire        pri,

    // --- observability ------------------------------------------------------
    output reg  [15:0] dbg_rows_done,   // lines whose list walk finished
    output reg  [15:0] dbg_overrun,     // lines cut off mid-walk
    output reg  [15:0] dbg_blits,       // tile rows blitted
    output wire [7:0]  dbg_n_act,       // enabled entries the LAST FULL scan found
    output wire [15:0] dbg_prescans,    // completed prescans, cumulative
    output wire [15:0] dbg_w0_or        // OR of every word 0 the last scan saw
);

  // ---------------------------------------------------------------------
  // Line buffer: {opaque, pri, pal_index[13:0]}, double buffered.
  //
  // The half on screen this line is the half the blitter fills on the NEXT
  // one, so it is erased behind the display's own read pointer, one entry per
  // free clock, on the blitter's write port.  It costs no clocks of its own:
  // the blitter can hold that port for at most MAX_ACT*16 = 2048 of a line's
  // 3584, only 320 entries can ever have been written (`sx < H_VISIBLE`), and
  // the erase trails the beam so it can never take an entry still to be read.
  //
  // ---- a generation tag cannot do this job, and the one that was here was
  // ---- the bug ---------------------------------------------------------
  //
  // It was ONE BIT per half, toggled each time that half began to be filled,
  // and a pixel counted as stale when its tag differed from the current one.
  // A bit toggled once per fill is back where it started after TWO fills, and
  // a half is filled every other line: a pixel written once and never
  // overwritten read stale for two lines and then FRESH AGAIN four lines
  // later, for ever.  The comment that stood here said "a pixel left from two
  // lines ago has the wrong generation", which is true at two lines and false
  // at four.  No tag of any width fixes this -- equality against a finite
  // counter always comes round again, and a stale pixel lives for ever.
  //
  // What it produced: stale sprite pixels reappearing every 4 scanlines over
  // the whole screen and over BOTH tilemaps, because sf_video puts sprites
  // above bg0 and bg1.  On the self-test grid screen, where the game's entire
  // sprite palette is black, that read as 26.4 % of bg0's lit pixels missing
  // with ZERO unexpected extras and a missing-pixel mask of vertical period
  // exactly 4.  On the attract screen, where 903 sprite palette entries are
  // not black, the same pixels read as the coloured vertical striping that
  // three sessions attributed to the tilemaps.  docs/DEBUG_LOG.md A24.
  // ---------------------------------------------------------------------
  // D23.  Two banks, split on the pixel's low address bit, so the blitter can
  // write TWO adjacent pixels in one clock.  Same 16 384 bits as the single
  // 1024-entry array it replaces -- each bank is 512 entries of 16 -- and
  // each has its own address port, so a pair starting on an ODD x (banks
  // o[n] and e[n+1]) is no harder than one starting on an even x.
  //
  // Sixteen clocks a sprite became eight, which is a quarter of what a sprite
  // costs its line.  The two frames of sixteen that were still losing sprite
  // lines were losing them to the engine's own serial time, not to the bus:
  // hardware delivered 547 reads on the busiest line whether the frame
  // finished or not (DEBUG_LOG A37).
  reg  [15:0] lbuf_e [0:511];
  reg  [15:0] lbuf_o [0:511];
  reg         wsel;
  reg  [15:0] rd_e, rd_o;
  reg         rd_sel;
  reg  [15:0] rd_q;
  reg  [9:0]  erase_ptr;
  // lbuf and rd_q are deliberately NOT reset.  For the first two raw lines
  // after reset `opaque` can therefore be true from whatever the RAM powers
  // up holding.  It cannot reach the screen: the CRTC starts at raw line 0
  // inside vblank, visible video starts at line 8, sf_video forces black
  // during blanking, and both halves are fully erased by raw line 2.
  // Recorded rather than fixed -- adding per-half valid state to suppress
  // an invisible transient is logic nobody can ever see working.

  // Both banks are read every clock and the low bit picks one.  The pick is
  // REGISTERED, not combinational: `rd_q` feeds the video mixer and from there
  // the HDMI clock, and a mux hung on the RAM output cost -0.076 ns of setup
  // there -- the first cut of D23 closed the 56 MHz core clock at +0.388 and
  // missed on HDMI.
  //
  // Registering it adds a CLOCK, not a pixel.  `hcnt` holds for eight clocks
  // (ce_pix), so the two-clock read lands inside the same pixel and the
  // address is simply hcnt -- exactly what the tile layers use.  This used to
  // run one pixel AHEAD (hcnt+1, and H_VISIBLE-hcnt under flip) on the
  // reasoning that a stage of delay needs a pixel of lead; that reasoning
  // holds only if hcnt advanced every clock.  It put the whole sprite layer
  // ONE PIXEL LEFT of the tilemaps: golden comparison (sim/golden, MAME state
  // into this RTL) had 5,447 of 5,813 differing pixels at FPGA(x)==MAME(x+1),
  // and 0 differing on seven frames after this line changed (DEBUG_LOG
  // O-WATER).  Flip stays an exact 180-degree rotation of the unflipped frame.
  wire [8:0] hnx = flip ? (H_VISIBLE[8:0] - 9'd1 - hcnt[8:0]) : hcnt[8:0];
  always @(posedge clk) begin
    rd_e   <= lbuf_e[{~wsel, hnx[8:1]}];
    rd_o   <= lbuf_o[{~wsel, hnx[8:1]}];
    rd_sel <= hnx[0];
    rd_q   <= rd_sel ? rd_o : rd_e;
  end

  // D19 removed the byte-pair cache and its RAM read lived here.  The rule it
  // carried is still true of every other array in this file: an inferred RAM
  // answers one clock AFTER the address, and sf_fgmap's first cut read its
  // equivalent combinationally and was a clock early on every byte.

  assign opaque    = rd_q[15];
  assign pri       = rd_q[14];
  assign pal_index = rd_q[13:0];

  wire [8:0] next_line = (vcnt == V_TOTAL[8:0] - 9'd1) ? 9'd0 : vcnt + 9'd1;

  // ---------------------------------------------------------------------
  // States.
  //
  // sf_dpram is a single registered read: `b_dout <= mem[b_addr]`.  `spr_addr`
  // is a register too, so an address assigned on edge X is presented to the
  // RAM during X+1 and its data is latchable on edge **X+2** -- and not
  // before, and not after.
  //
  // The first version of this module got that wrong in both walks: every
  // descriptor word was captured one state late, so `w0` held word 1, `w2`
  // held word 3, and the palette register held the X low byte.  The offline
  // checks against MAME could not see it because they tested the arithmetic,
  // not the FSM that feeds it.  Codex found it by reading the schedule
  // against this comment (docs/DEBUG_LOG.md A20).
  // ---------------------------------------------------------------------
  localparam [4:0] S_IDLE = 5'd0,
                   S_P0   = 5'd1,  S_P1  = 5'd2,  S_P2  = 5'd3,  S_P3 = 5'd4,
                   // D21: the prescan now reads words 2..5 as well, so the
                   // per-line walk does not have to read them again.
                   S_P4   = 5'd6,  S_P5  = 5'd7,  S_P6  = 5'd8,
                   S_SEL  = 5'd5,
                   S_ROM  = 5'd12, S_WAIT= 5'd13,
                   S_BLIT = 5'd14, S_NEXT= 5'd15;

  reg [4:0]  st;
  // D21.  `idx` held the entry number so S_T0..S_T5 could address it word
  // by word.  Nothing addresses the entry per line any more.

  // ---- the per-frame prescan -------------------------------------------
  // D21.  act_idx is gone with S_T0..S_T5: the entry number was only ever
  // kept so the per-line walk could address the entry again.
  reg [8:0]  act_y   [0:MAX_ACT-1];
  reg [3:0]  act_h   [0:MAX_ACT-1];
  // ---- D21: the rest of the entry, kept instead of re-read every line -----
  //
  // S_T0..S_T5 read words 0, 2, 3, 4 and 5 of the entry AGAIN for every line
  // the sprite covers -- six clocks a sprite a line, of data the prescan has
  // already walked past.  At sixty sprites on a line that is 360 clocks of a
  // 3584-clock line, and the line budget is what the sprite engine runs out
  // of: hardware delivers 540 reads on the line whether it completes or not
  // (DEBUG_LOG A36), so what separates a frame that finishes from one that
  // does not is how much serial work the engine has, not how much bus.
  //
  // ty and trow still have to be computed per line -- they depend on which
  // line of the sprite this is -- so what is stored is flip-Y and the tile
  // NUMBER, not the derived values.
  reg [15:0] act_tile [0:MAX_ACT-1];
  reg [8:0]  act_x    [0:MAX_ACT-1];
  reg [9:0]  act_att  [0:MAX_ACT-1];   // {pal[6:0], pri, flipx, flipy}
  reg [8:0]  n_act, n_fill, ai;   // 9 bits: MAX_ACT is 256 now
  // D19.  `slot` was the byte-pair cache's index into creuse/cready/scache
  // and had no other reader, so it went with them.

  // ---- there is no wasted byte any more (D19, was D12) -------------------
  //
  // The word WAS  f*0x100000 + trow*16 + khalf*8 + ty[3:1]  with the byte
  // chosen by ty[0], so one read returned the same half of two adjacent rows:
  // ten reads a tile row and ten bytes thrown away.  D12 kept the spare byte
  // in a cache so the next line could use it, which halved the cost on every
  // other line and left the OTHER line paying all ten.
  //
  // build_rom.py now de-interleaves each 32-byte tile-plane block so a word is
  // both halves of ONE row.  Five reads a tile row, on every line, nothing
  // thrown away and nothing to cache.  DECISIONS D19.

  // These went out with the D12 comment block they were sitting inside.  They
  // are the prescan's word registers and the per-sprite geometry, and none of
  // them belonged to the byte-pair cache.
  reg [8:0]  p_idx;
  reg [15:0] p_w0, p_w1;
  reg [15:0] p_w4;          // D21: word 4, latched on the way to S_P6
  reg [15:0] w2, w3;
  reg [8:0]  ypos, xpos;
  reg [3:0]  height, ty;
  reg        flipx, e_pri;
  reg [6:0]  pal;
  reg [15:0] trow;
  reg [2:0]  k;
  // Indexed {half, k} where half is the blit's x[3], so 16 slots of which 10
  // are used.  Declaring it [0:9] and indexing with that concatenation would
  // reach 12 and read a hole -- the out-of-range array index Quartus warned
  // about once already in sf_tilemap (L2).  Both halves are now written from
  // the same word, so the two writes are to {0,k} and {1,k}.
  reg [7:0]  pl [0:15];
  reg [4:0]  bx;

  // ---- intersection ----------------------------------------------------
  // In S_SEL it is evaluated against prescanned entry `ai`; from S_T0 on
  // against the copies latched into ypos/height.  Same arithmetic either way.
  wire [3:0] h_now = (st == S_SEL) ? act_h[ai] : height;
  wire [8:0] y_now = (st == S_SEL) ? act_y[ai] : ypos;
  wire [8:0] span  = {h_now, 4'd0};
  wire [8:0] top   = y_now - span;
  wire [8:0] dd    = next_line - top;             // mod 512, which IS the wrap
  wire       onl   = (dd < span);                 // enable checked at prescan
  wire [2:0] ntop  = dd[6:4];
  wire [2:0] nbot  = (h_now[2:0] - 3'd1) - ntop;

  // The prescan is started by the copy itself, not by a line number.
  //
  // It used to trigger at `next_line == V_VISIBLE + 2`.  V_VISIBLE is 240,
  // but the CRTC counts raw lines and its visible window is 8..247
  // (sf_crtc.sv V_VIS_START/V_VIS_END), so line 242 is six lines INSIDE
  // active display -- not the blanking line the old comment claimed.  The
  // copy does not begin until vblank_start at 248 and takes over 4096
  // clocks, more than one 3584-clock line.
  //
  // So the prescan ran before the copy and walked the PREVIOUS frame's
  // snapshot, then the copy replaced the buffer underneath it.  Every index
  // it had stored still pointed into that buffer, so each line fetched the
  // descriptor of a different sprite than the one whose ypos and height had
  // been used to select it: geometry and artwork from two different entries.
  // That is the broken-object symptom, and it is invisible in an offline
  // check of the arithmetic because the arithmetic was right.
  //
  // copy_done fires two clocks after the last write lands, mid-line, so it
  // cannot coincide with line_start (the copy ends ~514 clocks into the line
  // after vblank_start) and the prescan's ~1024 clocks finish well inside
  // that same line.  DEBUG_LOG A21.

  // ---- blit ------------------------------------------------------------
  // D23.  Two pixels a clock, so everything here is a pair.  `bx` steps by
  // two and the second pixel is bx+1, which under flipx is bxe-1 -- still
  // adjacent, still opposite parity, which is what lets the two banks take
  // them in the same clock.
  assign rom_hold = (st == S_WAIT) && (k != 3'd4);

  wire [3:0] bx1   = bx[3:0] + 4'd1;
  wire [3:0] bxe0  = flipx ? (4'd15 - bx[3:0]) : bx[3:0];
  wire [3:0] bxe1  = flipx ? (4'd15 - bx1)     : bx1;
  wire [2:0] bit0  = 3'd7 - bxe0[2:0];
  wire [2:0] bit1  = 3'd7 - bxe1[2:0];
  wire       hi0   = bxe0[3];
  wire       hi1   = bxe1[3];
  wire [4:0] pen0  = { pl[{hi0, 3'd4}][bit0], pl[{hi0, 3'd3}][bit0],
                       pl[{hi0, 3'd2}][bit0], pl[{hi0, 3'd1}][bit0],
                       pl[{hi0, 3'd0}][bit0] };
  wire [4:0] pen1  = { pl[{hi1, 3'd4}][bit1], pl[{hi1, 3'd3}][bit1],
                       pl[{hi1, 3'd2}][bit1], pl[{hi1, 3'd1}][bit1],
                       pl[{hi1, 3'd0}][bit1] };
  wire [8:0] sx0   = xpos + {5'd0, bx[3:0]};
  wire [8:0] sx1   = xpos + {5'd0, bx1};

  // ---- the line buffer's write port: blitter first, erase in the gaps ----
  //
  // `fsm_run` reproduces the guard the blit write used to sit behind -- the
  // FSM block is `if (rst) .. else if (line_start) .. else if (copy_done) ..
  // else case(st)`, so those three clocks never wrote and still must not.
  //
  // The erase trails the beam by two pixels, which is what makes this safe on
  // a simple dual-port RAM: the read address is {~wsel, hcnt} and the erase
  // address is {~wsel, erase_ptr} with erase_ptr + 2 < hcnt, so they are never
  // the same entry in the same clock and there is no read-during-write to
  // reason about.  Erasing the address being READ, in the clock it is read,
  // is what one port cannot do -- root CLAUDE.md 7 and
  // projects/vsystem/power_spikes/docs/LESSONS_LEARNED.md L24 are 11,264
  // flip-flops of that mistake.
  //
  // It always finishes: it needs H_VISIBLE advances, it may take one on any
  // clock the blitter is idle, and the blitter is busy for at most
  // MAX_ACT*16 = 2048 of a line's 3584.
  //
  // The bound is H_VISIBLE and not the literal 320 it started as.  Only
  // addresses below H_VISIBLE can ever have been written -- the blit is
  // guarded by `sx < H_VISIBLE` -- so a wider instance with a hard 320
  // would leave everything above it never erased, which is the stale
  // pixel this whole mechanism exists to prevent.  Every instance today
  // is 320, so this changes nothing now and is exactly the untested
  // special branch root CLAUDE.md 7 warns a new target walks into.
  wire        fsm_run  = ~rst & ~line_start & ~copy_done;
  wire        in_blit  = fsm_run && (st == S_BLIT);
  // Each pixel is still tested on its own: a transparent pen writes nothing
  // and an x past the visible edge writes nothing, exactly as before.
  wire        w0       = in_blit && (|pen0) && (sx0 < H_VISIBLE[8:0]);
  wire        w1       = in_blit && (|pen1) && (sx1 < H_VISIBLE[8:0]);
  wire        blit_we  = w0 | w1;
  wire        erase_do = ~blit_we && (erase_ptr < H_VISIBLE[9:0])
                         && ((erase_ptr + 10'd2) < {1'b0, hcnt});

  // sx0 and sx1 are adjacent, so exactly one is even and one is odd.  Each
  // bank therefore takes at most one of them, and their indices differ only
  // when the pair starts on an odd x.
  wire        e_from0 = ~sx0[0];                    // even bank takes pixel 0
  wire [8:0]  ea      = e_from0 ? {wsel, sx0[8:1]} : {wsel, sx1[8:1]};
  wire [8:0]  oa      = e_from0 ? {wsel, sx1[8:1]} : {wsel, sx0[8:1]};
  wire        e_we    = e_from0 ? w0 : w1;
  wire        o_we    = e_from0 ? w1 : w0;
  wire [15:0] d0      = {1'b1, e_pri, 2'b01, pal, pen0};
  wire [15:0] d1      = {1'b1, e_pri, 2'b01, pal, pen1};
  wire [15:0] ed      = e_from0 ? d0 : d1;
  wire [15:0] od      = e_from0 ? d1 : d0;

  // The erase engine clears BOTH banks at one index, which is two pixels a
  // clock as well -- it has to keep up with a blitter that now does two.
  // `erase_ptr` counts DISPLAY positions, so the guard above needs no change
  // under flip -- it still says "the beam has passed this by two".  What does
  // change is which entry that display position is: the pair it clears becomes
  // source columns H_VISIBLE-1-p and H_VISIBLE-2-p, one word as before since
  // erase_ptr advances by two.  The two-pixel margin survives the mirror: the
  // erase word stays at least one above the word being read.
  wire [9:0]  er_i    = flip ? (H_VISIBLE[9:0] - 10'd2 - erase_ptr) : erase_ptr;
  wire [8:0]  er_a    = {~wsel, er_i[8:1]};

  always @(posedge clk) begin
    if (blit_we) begin
      if (e_we) lbuf_e[ea] <= ed;
      if (o_we) lbuf_o[oa] <= od;
    end else if (erase_do) begin
      lbuf_e[er_a] <= 16'd0;
      lbuf_o[er_a] <= 16'd0;
    end

    if (rst || line_start) erase_ptr <= 10'd0;
    // D23.  Two a clock, matching the pair of banks it clears.
    else if (erase_do)     erase_ptr <= erase_ptr + 10'd2;
  end

  // n_act is cleared when a scan STARTS, so reading it directly cannot tell
  // "the scan found nothing" from "the scan is in progress" -- and the row
  // that reads it is drawn at raw lines 48-51, nowhere near the scan, which
  // is what made the last reading ambiguous rather than wrong.
  //
  // n_act_pub is written only when a scan COMPLETES and is never cleared, so
  // it always describes a finished walk.  Paired with a count of completed
  // scans, the three states separate:
  //
  //   dbg_prescans rising, dbg_n_act 0     the list really is empty
  //   dbg_prescans not rising              the trigger never fires
  //   dbg_prescans rising, dbg_n_act > 0   the engine has a list to draw
  // dbg_n_act stays EIGHT bits and saturates, because overlay row 21 packs
  // it with the blit count and widening it would be a new 16-bit route into
  // sf_dbg -- and two of this session's timing failures were exactly that.
  // FF therefore means "255 or more", which is still the answer to the only
  // question the row is asked: is the list empty, and is it near the cap.
  function [7:0] sat8(input [8:0] v);
    sat8 = v[8] ? 8'hFF : v[7:0];
  endfunction
  reg [7:0]  n_act_pub;
  reg [15:0] n_prescan;

  // Every word 0 the last completed scan saw, OR'd together.
  //
  // n_act = 0 has two possible causes and they need opposite fixes: the
  // buffer holds nothing (the copy or the CPU write path), or it holds data
  // whose enable bit is not where this code looks (bit 2, MAME
  // shadfrce.cpp:341 `source[0] & 0x0004`).  Row 6 counts CPU writes on the
  // BUS, which is not a reading of what the RAM contains -- one number that
  // cannot be cross-checked is the instrument this factory keeps being burned
  // by.  This is the second reading:
  //
  //   0x0000            the buffer really is empty -- look at the copy
  //   non-zero, no bit2 the data is there and the enable decode is wrong
  //   has bit 2 set     the scan saw enables and dropped them anyway
  reg [15:0] w0_or_acc, w0_or_pub;
  assign dbg_n_act    = n_act_pub;
  assign dbg_prescans = n_prescan;
  assign dbg_w0_or    = w0_or_pub;

  integer i;

  always @(posedge clk) begin
    if (rst) begin
      st <= S_IDLE; wsel <= 1'b0;
      n_act <= 9'd0; n_fill <= 9'd0; ai <= 9'd0; p_idx <= 9'd0;
      n_act_pub <= 8'd0; n_prescan <= 16'd0;
      w0_or_acc <= 16'd0; w0_or_pub <= 16'd0;
      rom_req <= 1'b0; rom_addr <= 25'd0; spr_addr <= 12'd0;
      dbg_rows_done <= 16'd0; dbg_overrun <= 16'd0; dbg_blits <= 16'd0;
      for (i = 0; i < 16; i = i + 1) pl[i] <= 8'd0;
    end else if (line_start) begin
      if (st == S_IDLE || st == S_NEXT) dbg_rows_done <= dbg_rows_done + 16'd1;
      else                              dbg_overrun   <= dbg_overrun   + 16'd1;
      wsel       <= ~wsel;
      // What this line filled becomes what the next line may reuse.  Rolling
      // it rather than keeping one vector is what stops a slot filled two
      // lines ago -- whose word has moved on -- from reading as current.
      rom_req    <= 1'b0;
      ai         <= 9'd0;
      st         <= S_SEL;
    end else if (copy_done) begin
      // A new prescan renumbers the active list, so slot N is a different
      // sprite from here on and nothing cached against the old numbering is
      // meaningful.
      p_idx     <= 9'd0;
      n_fill    <= 9'd0;
      n_act     <= 9'd0;
      w0_or_acc <= 16'd0;
      spr_addr  <= 12'd0;
      st        <= S_P0;
    end else begin
      case (st)
        S_IDLE: ;

        // ---- prescan: walk all 512 once, keep the enabled ones ----------
        // word 0's address was set on the edge that entered S_P0, so word 0
        // is latchable in S_P1 and word 1 -- addressed here -- in S_P2.
        S_P0: begin spr_addr <= {p_idx, 3'd1}; st <= S_P1; end
        S_P1: begin p_w0 <= spr_data; w0_or_acc <= w0_or_acc | spr_data;
                    spr_addr <= {p_idx, 3'd2}; st <= S_P2; end
        // D21a.  Only an entry that is ENABLED and will fit costs the four
        // extra reads.  Reading words 2-5 for all 512 made the prescan seven
        // clocks an entry -- 3584, a whole scanline -- and it stopped
        // finishing inside the line the copy ends in, which is the window the
        // header above says it has.  Sprites then drew from a half-built list
        // and dbg_n_act published zero (DEBUG_LOG A37).
        //
        // Disabled entries now cost three clocks and enabled ones seven, so
        // the walk is 512*3 + n_act*4: 1712 clocks at the 44 entries this game
        // averages and 2048 at the MAX_ACT of 128 -- the same budget it had
        // before D21, worst case included.
        S_P2: begin p_w1 <= spr_data;
          if (p_w0[2] && (n_fill != MAX_ACT[8:0])) begin
            spr_addr <= {p_idx, 3'd3}; st <= S_P3;
          end else if (p_idx == 9'd511) begin
            st        <= S_IDLE;
            n_act_pub <= sat8(n_fill);
            n_prescan <= n_prescan + 16'd1;
            w0_or_pub <= w0_or_acc;
          end else begin
            p_idx    <= p_idx + 9'd1;
            spr_addr <= {p_idx + 9'd1, 3'd0};
            st       <= S_P0;
          end
        end
        S_P3: begin w2 <= spr_data;
                    spr_addr <= {p_idx, 3'd4}; st <= S_P4; end
        S_P4: begin w3 <= spr_data;
                    spr_addr <= {p_idx, 3'd5}; st <= S_P5; end
        S_P5: begin p_w4 <= spr_data;          st <= S_P6; end
        // Reached only for an entry already known enabled and in range, so
        // the test that used to guard this is now in S_P2.
        S_P6: begin
          begin
            act_y  [n_fill] <= 9'h100 - {p_w0[0], p_w1[7:0]};
            act_h  [n_fill] <= {1'b0, p_w0[7:5]} + 4'd1;
            // D21.  Word 5 is on spr_data now, words 2-4 were latched on the
            // way here.  The "skip hole" fold and the +1 on X are MAME's and
            // move here unchanged from S_T4/S_T5 -- see MAME_AUDIT.
            act_tile[n_fill] <= {w2[7:0], w3[7:0]};
            act_x   [n_fill] <= {p_w4[0], 8'd0} + {1'b0, spr_data[7:0]} + 9'd1;
            // BIT 0 OF WORD 4 IS NOT PART OF THE COLOUR.  It is the X
            // position's high bit -- shadfrce.cpp:320 draws word 4 as
            //     | ---- ---- -pCc cccX |
            // and takes the colour as `source[4] & 0x003e`, bits 5..1, with
            // bit 0 MASKED OUT.  It is used one line above this as
            // `{p_w4[0], 8'd0}`, the 256 in the X position.
            //
            // This read p_w4[5:0] and therefore put the X high bit into the
            // palette, so every sprite at x >= 256 -- the right 64 pixels of
            // 320, which is a fifth of the screen -- drew from the palette
            // row NEXT to its own.  Reported from play on 2026-09-04 as
            // "both the enemy and me are shadows on the right fifth", which
            // is exactly what a character rendered through the wrong palette
            // row looks like.  Nothing in attract mode put a character far
            // enough right for long enough to catch it, and no counter can
            // see it: the sprite completes, the line completes, the pixels
            // are simply the wrong colour.
            act_att [n_fill] <= { (p_w4[5] ? ({1'b0, p_w4[5:1], 1'b0} ^ 7'h60)
                                           :  {1'b0, p_w4[5:1], 1'b0}),
                                  p_w4[6], p_w0[4], p_w0[3] };
            n_fill          <= n_fill + 9'd1;
            n_act           <= n_fill + 9'd1;
          end
          if (p_idx == 9'd511) begin
            st        <= S_IDLE;
            // This entry IS being kept, so the published count includes it.
            n_act_pub <= sat8(n_fill + 9'd1);
            n_prescan <= n_prescan + 16'd1;
            w0_or_pub <= w0_or_acc;
          end
          else begin
            p_idx    <= p_idx + 9'd1;
            spr_addr <= {p_idx + 9'd1, 3'd0};
            st       <= S_P0;
          end
        end

        // ---- per line: one list entry a clock ---------------------------
        S_SEL: begin
          if (ai == n_act) st <= S_IDLE;
          else if (onl) begin
            // D21.  Everything the six S_T states used to re-read is already
            // here.  Only the two values that depend on WHICH line this is
            // are computed: ty, which flip-Y reverses, and trow, which is the
            // tile number plus the row of the sprite counted from the bottom.
            ypos     <= act_y[ai];
            height   <= act_h[ai];
            trow     <= act_tile[ai] + {13'd0, nbot};
            xpos     <= act_x[ai];
            pal      <= act_att[ai][9:3];
            e_pri    <= act_att[ai][2];
            flipx    <= act_att[ai][1];
            ty       <= act_att[ai][0] ? (4'd15 - dd[3:0]) : dd[3:0];
            k        <= 3'd0;
            st       <= S_ROM;
          end else
            ai <= ai + 9'd1;
        end

        // D21.  S_T0..S_T5 stood here and re-read words 0, 2, 3, 4 and 5 of
        // the entry for every line the sprite covers.  The prescan walks the
        // same words once a frame, so it keeps them now and S_SEL goes
        // straight to S_ROM: six clocks a sprite a line, gone.

        // D19.  One word is now a whole 16-pixel row of one plane, so this is
        // five reads and the address has one term FEWER than before -- the
        // khalf offset is gone and ty is used whole instead of ty[3:1].
        // build_rom.py de-interleaves each 32-byte tile-plane block to make
        // that true; the region, its size and the plane spacing are unchanged.
        // D24.  High while a word is being acked and another of the same
        // sprite row follows.  Bounded at five by construction.
        S_ROM: begin
          // D20.  tile*80 + ty*5 + plane, so a row's five planes are five
          // CONSECUTIVE words: one activate and four hits where D19 still
          // paid five activates a megabyte apart.  80 is (t<<6)+(t<<4) and
          // 5 is (y<<2)+y, which is two adders more than D19 and still fewer
          // terms than the layout before it.
          rom_addr <= spr_base_w
                    //
                    // Every concatenation is 25 bits BEFORE the shift.  A
                    // shift in Verilog keeps the width of its left operand,
                    // so {3'd0, trow} << 6 is nineteen bits holding a
                    // twenty-three bit value and silently drops the top of
                    // every tile index above 8191.  check_widths.py does not
                    // see this -- it checks concatenations against their
                    // target, not shifts against their own operand.
                    + ({9'd0, trow} << 6) + ({9'd0, trow} << 4)
                    + ({21'd0, ty} << 2) + {21'd0, ty}
                    + {22'd0, k};
          rom_req  <= 1'b1;
          st       <= S_WAIT;
        end

        S_WAIT: if (rom_ack) begin
          // Half 0 is the LEFT eight pixels and the blit reads it as
          // pl[{1'b0, k}]; the image is big-endian, so it is the HIGH byte.
          // Getting this pair the wrong way round mirrors every sprite in
          // eight-pixel columns, which reads as corrupt artwork rather than
          // as a byte-order fault.
          pl[{1'b0, k}] <= rom_data[15:8];
          pl[{1'b1, k}] <= rom_data[7:0];
          // D24.  Stay in S_WAIT with `rom_req` still high and the next word
          // already addressed -- the five are consecutive since D20, so the
          // next address is rom_addr + 1.  That is D15's contract, and it is
          // what lets the arbiter keep the grant instead of handing it away
          // and letting another client evict this row between the words.
          if (k == 3'd4) begin
            rom_req <= 1'b0;
            bx      <= 5'd0;
            st      <= S_BLIT;
          end else begin
            rom_addr <= rom_addr + 25'd1;
            k        <= k + 3'd1;
          end
        end

        // Sixteen pixels, one a clock.  Overwriting IS the priority model:
        // entry 511 writes last and therefore wins.
        S_BLIT: begin
          // The write itself lives with the line buffer, decoded from this
          // state, so the erase engine can share the one write port.
          // D23.  Two pixels a clock, so eight passes instead of sixteen.
          if (bx == 5'd14) begin
            dbg_blits <= dbg_blits + 16'd1;
            st        <= S_NEXT;
          end
          bx <= bx + 5'd2;
        end

        S_NEXT: begin ai <= ai + 9'd1; st <= S_SEL; end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
