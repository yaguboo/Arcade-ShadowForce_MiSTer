//============================================================================
//  Shadow Force -- 16x16 tilemap layer with a line buffer
//
//  Covers both background layers.  They differ only in how a map entry is
//  packed, which is a parameter:
//
//      bg1   TWO_WORD=0   one word per tile    tile[11:0], colour[15:12]+64
//                         opaque, no flip
//      bg0   TWO_WORD=1   two words per tile   word1[13:0] tile
//                         word0[4:0] colour (folded), word0[7:6] flip Y,X
//                         transparent on pen 0
//
//  ---- the ROM decode, and why it is written down here --------------------
//
//  MAME's layout is
//
//      bg16x16x6 = { 16,16, RGN_FRAC(1,3), 6,
//        { RGN_FRAC(0,3)+8, RGN_FRAC(0,3), RGN_FRAC(1,3)+8, RGN_FRAC(1,3),
//          RGN_FRAC(2,3)+8, RGN_FRAC(2,3) },
//        { STEP8(0,1), STEP8(16*16,1) }, { STEP16(0,16) }, 2*16*16 }
//
//  Worked through into word addresses, that is: for third f (0..2), tile N,
//  row y and half h (h=0 is x 0..7, h=1 is x 8..15), everything needed sits
//  in ONE big-endian 16-bit word at
//
//      word = TILE_BASE_W + f*0x80000 + N*32 + y + h*16
//
//  with word[15:8] carrying plane (4-2f) and word[7:0] plane (5-2f), MSB
//  first in x.  Six words per tile row, 16 pixels -- which is exactly the
//  96 bits per row that docs/HARDWARE.md section 12's budget assumes.
//
//  **This derivation was checked against MAME's own layout arrays** by
//  decoding eight tiles both ways from the real ROM: 2048 pixels, 1568 of
//  them non-zero, zero mismatches.  The non-zero count is part of the check
//  -- two decoders that both return zero agree about nothing.
//
//  ---- the two-word map entry is not atomic, and the game knows ----------
//
//  With TWO_WORD=1 the tile number and its colour are separate RAM words read
//  on consecutive grants.  docs/HARDWARE.md 12b measured that the game writes
//  bg map RAM 97.6 % of the time DURING ACTIVE DISPLAY, so a write can land
//  between the two reads and produce a tile carrying one entry's colour with
//  another's number.
//
//  This does not try to prevent that, because the real board does not either
//  -- there is no buffering of tilemap RAM on the PCB, and what its video
//  customs do when the CPU writes mid-scan is UNVERIFIED.  Instead it is
//  COUNTED: dbg_tear rises when a CPU write hits the entry being fetched.
//  18 bg writes a frame against roughly 4 800 tile fetches makes collisions
//  rare, and one wrong tile for one frame is probably invisible -- but that
//  is a prediction, and the counter is how it stops being one.
//
//  ---- line budget --------------------------------------------------------
//
//  21 tiles (20 visible plus one for the scroll remainder) x 6 words = 126
//  memory reads per line, plus 21x16 = 336 clocks of line-buffer writing.
//  A line is 448 pixels x 8 = 3584 clocks at 56 MHz, and the SDRAM returns a
//  word about every 9 clocks, so one layer costs roughly 1470 clocks.
//
//  ONE layer fits comfortably.  Three plus sprites does not -- that is the
//  10 M words/s in docs/DECISIONS.md D4, and it is why the burst work has to
//  happen before bg0, fg and sprites all run at once.
//============================================================================
`default_nettype none

module sf_tilemap #(
    parameter int  MAP_BASE  = 'h1000,   // word offset inside the bg RAM block
    parameter bit  TWO_WORD  = 1'b0,     // 1 = bg0's two-word map entries
    parameter int  H_VISIBLE = 320,
    parameter int  V_START   = 8,        // first visible screen line
    parameter int  V_TOTAL   = 272
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,

    input  wire [8:0]  hcnt,
    input  wire [8:0]  vcnt,
    input  wire        line_start,      // one ce_pix pulse at hcnt == 0

    input  wire [8:0]  scrollx,
    input  wire [8:0]  scrolly,

    // --- map RAM, read-only, THROUGH A SHARED PORT --------------------------
    //
    // bg0 and bg1 live in one RAM block with one B port, and both fetchers
    // run during the same line.  So this is a request/grant rather than a
    // free read: hold map_addr and map_req until map_gnt, which is the same
    // contract the SDRAM arbiter uses.  map_data is valid one clock after
    // the grant.
    output wire [12:0] map_addr,
    input  wire [15:0] map_data,
    output wire        map_req,
    input  wire        map_gnt,

    // --- tile ROM, through the arbiter --------------------------------------
    output wire [24:0] rom_addr,
    input  wire [15:0] rom_data,
    output wire        rom_req,
    // D15.  High while a word of the six-word fetch is being acked and
    // another one follows.  `rom_req` never drops inside the group and
    // `rom_addr` is combinational on `k`, so the next address is already
    // valid the clock after the ack -- which is exactly the contract
    // sf_memarb's `hold` asks for.  Bounded at six by construction.
    output wire        rom_hold,
    input  wire        rom_ack,
    input  wire [24:0] tile_base_w,      // TILES_BASE_W, from sf_rommap.svh

    // --- pixel out, for the current hcnt ------------------------------------
    output wire [13:0] pal_index,        // palette word address
    output wire        opaque,           // pen != 0

    // --- a CPU write landing inside the entry being fetched -----------------
    input  wire        cpu_map_we,       // CPU wrote the bg RAM this clock
    input  wire [12:0] cpu_map_a,        // ... at this word address

    // --- observability -------------------------------------------------------
    output reg  [15:0] dbg_rows_done,    // lines fully fetched, cumulative
    output reg  [15:0] dbg_overrun,      // lines that ran out of time
    output reg  [15:0] dbg_tear          // entries torn by a mid-read write
);

  localparam int THIRD_W = 'h80000;      // 1 MB region third, in words
  localparam int N_TILES = (H_VISIBLE / 16) + 1;   // 21 for 320 wide

  // ---------------------------------------------------------------------
  // Line buffer, double buffered.
  //
  // Each entry is {colour[6:0], pen[5:0]}.  The palette address is that plus
  // 0x2000, which is gfx element 2's colour base -- so the stored value is
  // exactly the low 13 bits of the address and the top bit is a constant.
  // ---------------------------------------------------------------------
  reg [12:0] lbuf [0:1023];              // 2 x 512
  reg        wsel;                       // which half is being written

  reg  [9:0] wr_a;
  reg [12:0] wr_d;
  reg        wr_e;
  wire [9:0] rd_a = {~wsel, hcnt[8:0]};
  reg [12:0] rd_q;

  always @(posedge clk) begin
    if (wr_e) lbuf[wr_a] <= wr_d;
    rd_q <= lbuf[rd_a];
  end

  // rd_q is one clock late, which lines up with the palette RAM's own clock
  // of latency downstream.  Both are accounted for in sf_video's pipeline.
  assign pal_index = {1'b1, rd_q};
  assign opaque    = (rd_q[5:0] != 6'd0);

  // ---------------------------------------------------------------------
  // Which tilemap row this line needs.
  //
  // The scroll is against the SCREEN row, not the raw scanline: screen row 0
  // is raw line V_START.  Fetching happens a line ahead, so the target is
  // vcnt+1.  Getting this off by one shifts the whole layer up or down by a
  // line, which looks like a scroll bug rather than a fetch-timing one.
  // ---------------------------------------------------------------------
  wire [8:0] next_line = (vcnt == V_TOTAL[8:0] - 9'd1) ? 9'd0 : vcnt + 9'd1;
  // RAW LINE, NOT SCREEN ROW.
  //
  // MAME's tilemaps draw into the SCREEN BITMAP, whose coordinates are raw
  // scanlines: shadfrce.cpp:812 is
  //     set_raw(XTAL(28'000'000)/4, 448, 0, 320, 272, 8, 248)
  // so the visible window is raw 8..247 and a tilemap with scrolly = 0 puts
  // map row 0 at raw line 0 -- which means the TOP VISIBLE LINE shows map
  // row 8, not map row 0.
  //
  // This subtracted V_START and so drew map row 0 at raw line 8, putting
  // every tile layer EIGHT LINES LOW.  The sprite engine does not subtract
  // it (sf_sprite.sv:343 compares against next_line directly), so sprites
  // were right and the tile layers were not, and the two drifted apart by a
  // fixed 8.
  //
  // Measured 2026-09-04 against MAME's own PLAYER SELECT, from a screenshot
  // taken while somebody played: the orange portrait frames -- tilemap --
  // sat at y 46/126/136 on the board against 38/118/129 in MAME, exactly +8
  // on all three, while their vertical edges at x 31/96/160/223/288 matched
  // to the pixel.  Reported as "the portrait does not sit properly inside
  // its frame", which is what an 8-line split between sprites and tiles
  // looks like.
  wire [8:0] screen_y  = next_line;

  wire [8:0] ty        = screen_y + scrolly;      // wraps at 512 naturally

  reg  [4:0] row;
  reg  [3:0] py;
  reg  [4:0] first_col;
  reg  [3:0] fine;

  // ---------------------------------------------------------------------
  // Fetch sequencer
  // ---------------------------------------------------------------------
  localparam [3:0] S_IDLE  = 4'd0,
                   S_MAP0  = 4'd1,   // map address issued
                   S_MAP1  = 4'd2,   // dpram latency
                   S_MAP2  = 4'd3,   // second map word (bg0 only)
                   S_LATCH = 4'd4,
                   S_ROM   = 4'd5,
                   S_CCHK  = 4'd9,   // D17: read the tile-row cache tag
                   S_CHIT  = 4'd10,  // D17: decide hit, one clock later
                   S_CRD   = 4'd11,  // D17: one word out of the cache
                   S_WAIT  = 4'd6,
                   S_BLIT  = 4'd7,
                   S_DONE  = 4'd8;

  reg [3:0]  st;
  reg [4:0]  t;                       // which tile of the line, 0..N_TILES-1
  reg [2:0]  k;                       // which of the six ROM words
  reg [15:0] w [0:5];

  // ---- D17: one line's tile rows, cached --------------------------------
  //
  // Every tile on a line is fetched at the SAME y, so two tiles with the same
  // index and the same flip need byte-for-byte identical words out of a
  // read-only ROM.  MAME says a bg0 line draws 3.4 distinct tiles of 21 and a
  // bg1 line 9.5 -- so most of this layer's 126 words a line are the same six
  // re-read.  With both bg layers and fg cached the worst line in 496,320
  // measured ones falls from 752 words to 458, which is below the 465 the bus
  // already delivers (DEBUG_LOG A30, tools/mame_line_demand2.lua).
  //
  // Valid is cleared at every line start, because `py` changes and the cached
  // words are for the old one.  That is the whole coherency argument: the ROM
  // cannot change, and the only other key is y.
  localparam int CIDX = 5;                       // 32 entries, worst seen 21
  // Eight words a slot, not six, because the index is {cidx, k} and k is
  // three bits -- 31*8+5 = 253 has to be in range.  Two slots of every eight
  // are never written; 4096 bits is cheaper than a multiply.
  // no_rw_check because a read and a write to these can never land in the
  // same clock: the read is in S_CCHK/S_ROM (or S_TCHK/S_ROM) and the write
  // is in S_WAIT, and the FSM is in exactly one state.  Without it Quartus
  // adds read-during-write pass-through logic to match RTL semantics it
  // cannot prove are unreachable -- six Warning (276020) and the logic to go
  // with it.  This states the design fact; it does not silence the warning.
  (* ramstyle = "no_rw_check" *)
  reg [15:0] tdat [0:(1<<CIDX)*8-1];             // 256 x 16 = 4096 bits
  (* ramstyle = "no_rw_check" *)
  reg [9:0]  ttag [0:(1<<CIDX)-1];
  reg        tval [0:(1<<CIDX)-1];
  reg [15:0] tdat_q;
  reg [9:0]  ttag_q;
  reg        tval_q;
  reg        chit;
  integer    ci;
  reg [13:0] tile;
  reg [6:0]  colour;
  reg        flipx, flipy;
  reg [3:0]  bx;                      // pixel within the tile, 0..15
  reg [15:0] map_w0;

  wire [9:0] map_ent = {5'd0, row} * 10'd32 + {5'd0, (first_col + t)};
  assign map_addr = TWO_WORD ? (MAP_BASE[12:0] + {2'd0, map_ent, 1'b0} + {12'd0, (st == S_MAP2)})
                             : (MAP_BASE[12:0] + {3'd0, map_ent});
  assign map_req  = (st == S_MAP0) || (st == S_MAP2);

  wire [3:0] py_eff = flipy ? (4'd15 - py) : py;
  wire [2:0] rf = k[2:1];
  wire       rh = k[0];

  assign rom_addr = tile_base_w
                  + ({22'd0, rf} * THIRD_W[24:0])
                  + ({11'd0, tile} << 5)
                  + {21'd0, py_eff}
                  + (rh ? 25'd16 : 25'd0);
  wire [CIDX-1:0] cidx = tile[CIDX-1:0];
  wire [9:0]      ctag = {flipy, tile[13:CIDX]};

  // NOT asserted on a cache hit: S_ROM is entered either way and the hit path
  // must never reach the arbiter.
  assign rom_req  = ((st == S_ROM) || (st == S_WAIT)) && !chit;
  assign rom_hold = (st == S_WAIT) && (k != 3'd5);

  // ---------------------------------------------------------------------
  // Pixel assembly, from the six latched words.
  //
  // The six words are indexed k = f*2 + h, which is the order S_ROM fetches
  // them in (rf = k[2:1], rh = k[0]).  So third f, half h is at k = 2f + h,
  // and the three indices below are the only correct ones.
  //
  // The first version of this wrote `{1'b1, bh} + 3'd3` for third 2, which
  // is 5 or **6** -- one past the end of a six-element array. Quartus said
  // so ("index expression is not wide enough to address all of the elements
  // in the array") and it was right about more than the width: the third-1
  // index was off by one as well. Both were caught by the warning, which is
  // the argument for the project's zero-project-owned-warnings rule.
  //
  // Within a word: [15:8] is the byte MAME places at plane 4-2f and [7:0]
  // the byte at plane 5-2f, MSB first in x -- so bit (7-xs) of the low byte
  // is w[k][7-xs] and the same bit of the high byte is w[k][8 + (7-xs)].
  // ---------------------------------------------------------------------
  wire       bh  = bx[3];
  wire [2:0] bxs = bx[2:0];
  wire [2:0] sh  = 3'd7 - bxs;           // bit within the byte, MSB is x=0

  wire [2:0] k0 = {2'd0, bh};            // third 0 -> 0 or 1
  wire [2:0] k1 = 3'd2 + {2'd0, bh};     // third 1 -> 2 or 3
  wire [2:0] k2 = 3'd4 + {2'd0, bh};     // third 2 -> 4 or 5

  wire [3:0] lo_b = {1'b0, sh};          // 0..7   word[7:0]
  wire [3:0] hi_b = {1'b1, sh};          // 8..15  word[15:8]

  wire [5:0] pen = {
      w[k0][lo_b],      // plane 5  third 0, low byte
      w[k0][hi_b],      // plane 4  third 0, high byte
      w[k1][lo_b],      // plane 3  third 1, low byte
      w[k1][hi_b],      // plane 2  third 1, high byte
      w[k2][lo_b],      // plane 1  third 2, low byte
      w[k2][hi_b]       // plane 0  third 2, high byte
  };

  wire [3:0] bx_eff = flipx ? (4'd15 - bx) : bx;
  wire [9:0] px = {5'd0, t} * 10'd16 + {6'd0, bx_eff} - {6'd0, fine};

  integer i;
  always @(posedge clk) begin
    wr_e <= 1'b0;

    if (rst) begin
      st            <= S_IDLE;
      t             <= 5'd0;
      k             <= 3'd0;
      wsel          <= 1'b0;
      dbg_rows_done <= 16'd0;
      dbg_overrun   <= 16'd0;
      dbg_tear      <= 16'd0;
      row <= 5'd0; py <= 4'd0; first_col <= 5'd0; fine <= 4'd0;
      tile <= 14'd0; colour <= 7'd0; flipx <= 1'b0; flipy <= 1'b0;
      bx <= 4'd0; map_w0 <= 16'd0;
      for (i = 0; i < 6; i = i + 1) w[i] <= 16'd0;
    end else begin
      // A write to either word of the entry currently being read.  Only
      // meaningful for TWO_WORD, where the two words are read separately.
      if (TWO_WORD && cpu_map_we
          && (st == S_MAP0 || st == S_MAP1 || st == S_MAP2 || st == S_LATCH)
          && (cpu_map_a[12:1] == map_addr[12:1]))
        dbg_tear <= dbg_tear + 16'd1;

      if (line_start) begin
        // A line that has not finished fetching is a dropped line, not a
        // slow one.  Count it rather than letting it show up as a glitch
        // nobody can name -- Power Spikes needed exactly this counter for
        // its sprite engine.
        if (st != S_IDLE && st != S_DONE) dbg_overrun <= dbg_overrun + 16'd1;
        else if (st == S_DONE)            dbg_rows_done <= dbg_rows_done + 16'd1;
        // A skipped blanking line leaves st at S_IDLE, so it counts as
        // neither completed nor dropped -- which is right, nothing was
        // attempted.  The counters now describe the 240 lines that matter.

        wsel      <= ~wsel;
        row       <= ty[8:4];
        py        <= ty[3:0];
        first_col <= scrollx[8:4];
        fine      <= scrollx[3:0];
        t         <= 5'd0;
        k         <= 3'd0;
        chit      <= 1'b0;
        // D17.  py has changed, so every cached row is for the wrong line.
        for (ci = 0; ci < (1<<CIDX); ci = ci + 1) tval[ci] <= 1'b0;
        st        <= S_MAP0;
      end else begin
        case (st)
          S_IDLE: ;

          // map_addr is combinational off `t`; the dpram answers one clock
          // after the GRANT, so S_MAP1 exists to spend that clock.  Waiting
          // for map_gnt is what lets bg0 and bg1 share one port.
          S_MAP0: if (map_gnt) st <= S_MAP1;

          S_MAP1: begin
            if (TWO_WORD) begin
              map_w0 <= map_data;      // word 0: colour and flip
              st     <= S_MAP2;
            end else begin
              // bg1: tile[11:0], colour[15:12] + 64
              tile   <= {2'd0, map_data[11:0]};
              colour <= 7'd64 + {3'd0, map_data[15:12]};
              flipx  <= 1'b0;
              flipy  <= 1'b0;
              st     <= S_CCHK;
            end
          end

          S_MAP2: if (map_gnt) st <= S_LATCH;   // second word, same handshake

          S_LATCH: begin
            // bg0: word1[13:0] is the tile; word0 carries colour and flip.
            // "skip hole": MAME does `if (colour & 0x10) colour ^= 0x30`,
            // which folds the used ranges around a gap in the palette.
            // Getting it wrong gives correct artwork in wrong colours.
            tile   <= map_data[13:0];
            colour <= map_w0[4] ? ({2'd0, map_w0[4:0]} ^ 7'h30)
                                : {2'd0, map_w0[4:0]};
            flipy  <= map_w0[7];
            flipx  <= map_w0[6];
            st     <= S_CCHK;
          end

          // D17.  `tile` and `flipy` are registered by now, so the tag read
          // and the compare are each their own clock and neither lands in the
          // map handshake's path.  Two clocks a tile against six SDRAM
          // transactions saved on a hit.
          S_CCHK: begin
            ttag_q <= ttag[cidx];
            tval_q <= tval[cidx];
            st     <= S_CHIT;
          end

          S_CHIT: begin
            chit <= tval_q && (ttag_q == ctag);
            st   <= S_ROM;
          end

          S_ROM: begin
            tdat_q <= tdat[{cidx, k}];
            st     <= chit ? S_CRD : S_WAIT;
          end

          S_CRD: begin
            w[k] <= tdat_q;
            if (k == 3'd5) begin
              k  <= 3'd0;
              bx <= 4'd0;
              st <= S_BLIT;
            end else begin
              k  <= k + 3'd1;
              st <= S_ROM;
            end
          end

          S_WAIT: if (rom_ack) begin
            w[k]           <= rom_data;
            tdat[{cidx,k}] <= rom_data;          // D17: fill as it arrives
            if (k == 3'd5) begin
              // Marked valid only once all six words are in.  A tile cut off
              // by the line ending would otherwise be served as a complete
              // one on the next line, at the wrong y.
              ttag[cidx] <= ctag;
              tval[cidx] <= 1'b1;
              k  <= 3'd0;
              bx <= 4'd0;
              st <= S_BLIT;
            end else begin
              k  <= k + 3'd1;
              st <= S_ROM;
            end
          end

          S_BLIT: begin
            // One pixel a clock.  px can go negative-as-wrapped for the
            // first tile when `fine` is non-zero, and past H_VISIBLE for the
            // last; both are dropped rather than clamped, because clamping
            // would smear the edge pixel across the border.
            if (px < H_VISIBLE[9:0]) begin
              wr_a <= {wsel, px[8:0]};
              wr_d <= {colour, pen};
              wr_e <= 1'b1;
            end
            if (bx == 4'd15) begin
              bx <= 4'd0;
              if (t == N_TILES[4:0] - 5'd1) st <= S_DONE;
              else begin
                t  <= t + 5'd1;
                st <= S_MAP0;
              end
            end else begin
              bx <= bx + 4'd1;
            end
          end

          S_DONE: ;

          default: st <= S_IDLE;
        endcase
      end
    end
  end

endmodule

`default_nettype wire
