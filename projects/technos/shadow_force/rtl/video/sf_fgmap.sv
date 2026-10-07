//============================================================================
//  Shadow Force -- foreground text layer, 8x8 4bpp
//
//  64 x 32 map of 8x8 tiles at 140000-141FFF, two words per tile, drawn last
//  and transparent on pen 0.  docs/HARDWARE.md sections 3, 7 and 8.
//
//      word0[7:0]  tile[7:0]
//      word1[3:0]  tile[11:8]
//      word1[7:4]  colour     -> gfx element 0, colour index = colour * 4
//
//  gfx 0 has 16 colours per palette entry and a colour base of 0x0000, so the
//  palette address is (colour*4)*16 + pen = colour*64 + pen.
//
//  **This layer does not scroll.**  The memory map has scroll registers for
//  bg0 and bg1 only (1C0000-1C0007), so there is no fine offset and exactly
//  40 tiles cover the 320-pixel line.  That is why this is simpler than
//  sf_tilemap despite doing the same job.
//
//  ---- the ROM decode ------------------------------------------------------
//
//  MAME's layout is
//
//      fg8x8x4 = { 8,8, RGN_FRAC(1,1), 4,
//        { 0, 2, 4, 6 },
//        { 1, 0, 8*8+1, 8*8+0, 16*8+1, 16*8+0, 24*8+1, 24*8+0 },
//        { 0*8, 1*8, ... 7*8 }, 4*8*8 }
//
//  The four planes are packed INSIDE one byte, two pixels at a time, so a
//  tile row is four bytes -- one per x-pair, eight bytes apart:
//
//      byte = N*32 + p*8 + y        for pair p = 0..3
//
//  and inside that byte the **even** pixel of the pair takes the LOWER bit of
//  each plane, because xoffset is {1, 0, 65, 64, ...}.  That is the opposite
//  of the obvious reading and the first check of this derivation failed on it
//  -- 144 of 384 pixels came back swapped in pairs.  It now matches MAME's
//  own arrays on real ROM bytes: 384 pixels, 192 non-zero, 0 mismatches.
//
//  Consecutive y share a 16-bit word (byte N*32+p*8+y, y and y^1), so half of
//  every word fetched belongs to the next scanline.  Four word reads per tile
//  row, 160 per line.  docs/HARDWARE.md section 12.
//============================================================================
`default_nettype none

module sf_fgmap #(
    parameter int H_VISIBLE = 320,
    parameter int V_START   = 8,
    parameter int V_TOTAL   = 272
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,

    input  wire [8:0]  hcnt,
    input  wire [8:0]  vcnt,

    // Flip screen.  Only ONE thing in this module cares, and it is the byte
    // cache below: it is the only structure here that crosses a line
    // boundary, so it is the only one that can hold an assumption about
    // WHICH line comes next.  D17's tile caches are cleared at every
    // line_start and are direction-agnostic.
    input  wire        flip,
    input  wire        line_start,

    // --- fg map RAM, B port -------------------------------------------------
    output wire [11:0] map_addr,
    input  wire [15:0] map_data,

    // --- char ROM, through the arbiter --------------------------------------
    output wire [24:0] rom_addr,
    input  wire [15:0] rom_data,
    output wire        rom_req,
    // D15.  See sf_tilemap: same structure, four words instead of six.
    output wire        rom_hold,
    input  wire        rom_ack,
    input  wire [24:0] chars_base_w,

    // --- pixel out ------------------------------------------------------------
    output wire [13:0] pal_index,
    output wire        opaque,

    // --- observability --------------------------------------------------------
    output reg  [15:0] dbg_rows_done,
    output reg  [15:0] dbg_overrun,
    // How far it got before the line ran out.  "0 lines completed" cannot
    // tell a fetch that is two tiles short from one that is structurally
    // broken, and those need opposite fixes.  This is the LOWEST tile index
    // ever reached at a cut-off, so one bad line cannot hide behind good
    // ones -- and 0x3F means it has never been cut off at all.
    output reg  [5:0]  dbg_min_t
);

  localparam int N_TILES = H_VISIBLE / 8;      // 40, exact, no scroll

  // ---------------------------------------------------------------------
  // Line buffer, double buffered.  {colour[3:0], pen[3:0]}.
  // ---------------------------------------------------------------------
  reg [7:0] lbuf [0:1023];
  reg       wsel;

  reg  [9:0] wr_a;
  reg  [7:0] wr_d;
  reg        wr_e;
  wire [9:0] rd_a = {~wsel, hcnt[8:0]};
  reg  [7:0] rd_q;

  always @(posedge clk) begin
    if (wr_e) lbuf[wr_a] <= wr_d;
    rd_q <= lbuf[rd_a];
  end

  // palette address = colour*64 + pen
  assign pal_index = {4'd0, rd_q[7:4], 2'b00, rd_q[3:0]};
  assign opaque    = (rd_q[3:0] != 4'd0);

  // ---------------------------------------------------------------------
  // Which map row this line needs.  No scroll, so this is just the screen
  // row of the line being fetched, which is one ahead of the one on screen.
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

  reg [4:0] row;
  reg [2:0] py;

  // ---------------------------------------------------------------------
  // Fetch sequencer
  // ---------------------------------------------------------------------
  localparam [3:0] S_IDLE  = 4'd0,
                   S_MAP0  = 4'd1,
                   S_MAP1  = 4'd2,
                   S_MAP2  = 4'd3,
                   S_LATCH = 4'd4,
                   S_ROM   = 4'd5,
                   S_WAIT  = 4'd6,
                   S_BLIT  = 4'd7,
                   S_DONE  = 4'd8,
                   // The cached path.  Separate states rather than a flag
                   // inside S_ROM, so rom_req -- which is decoded from the
                   // state -- is low on a cached line by construction and is
                   // never withdrawn from under a grant (A8).
                   S_CA    = 4'd9,
                   S_CD    = 4'd10,
                   // D17.  A SECOND cache on a different axis: S_CA/S_CD is
                   // the byte-pair cache, keyed on tile POSITION and serving
                   // the next line.  These are keyed on the tile NUMBER and
                   // serve this one, because MAME says a line draws 1.6
                   // distinct fg tiles of 40.
                   S_TCHK  = 4'd11,
                   S_THIT  = 4'd12,
                   S_TRD   = 4'd13;

  reg [3:0]  st;
  reg [5:0]  t;                  // tile along the line, 0..39
  reg [1:0]  k;                  // which of the four bytes (x-pair)
  reg [7:0]  b [0:3];            // the four bytes, one per x-pair
  reg [11:0] tile;
  reg [3:0]  colour;
  reg [2:0]  bx;                 // pixel within the tile, 0..7
  reg [15:0] map_w0;

  // two words per tile entry, so the map word address is 2*(row*64 + col)
  wire [10:0] map_ent = {6'd0, row} * 11'd64 + {5'd0, t};
  assign map_addr = {map_ent, 1'b0} + {11'd0, (st == S_MAP2)};

  // byte N*32 + k*8 + y -> word, and which half of it.
  //
  // Computed 18 bits wide and then narrowed deliberately.  The value never
  // exceeds 17 bits -- 4095*32 + 24 + 7 = 131 071 = 2^17-1 -- but a sum of
  // three 17-bit terms is an 18-bit expression, and Verilog truncating it
  // back to 17 is a warning rather than a bug only because of that bound.
  // Saying so explicitly keeps the project-owned warning count at zero and
  // records why the narrower width is safe.
  wire [17:0] byte_off18 = {1'b0, tile, 5'd0}      // tile * 32   1+12+5 = 18
                         + {13'd0, k, 3'b000}      // pair * 8   13+2+3 = 18
                         + {15'd0, py};            //            15+3   = 18
  wire [16:0] byte_off = byte_off18[16:0];
  assign rom_addr = chars_base_w + {9'd0, byte_off[16:1]};
  // NOT gated by use_cache.  A cached line never enters S_ROM or S_WAIT at
  // all -- it runs S_CA/S_CD instead -- so the request is low by construction
  // rather than by being switched off underneath a grant.  The first cut did
  // gate it here, and withdrawing a request while a grant is in flight is the
  // handshake fault DEBUG_LOG A8 already cost a hardware run for.
  // ---- D17: this line's tile rows, by tile NUMBER -----------------------
  //
  // Forty fg tiles a line come from an average of 1.6 distinct ones, so the
  // same four words are read thirty-eight times over.  Keyed on the tile
  // number, cleared every line because py changes.  The index is {cidx, k}
  // with k exactly two bits, so 32 x 4 = 128 entries with no padding.
  localparam int TIDX = 5;
  // no_rw_check because a read and a write to these can never land in the
  // same clock: the read is in S_CCHK/S_ROM (or S_TCHK/S_ROM) and the write
  // is in S_WAIT, and the FSM is in exactly one state.  Without it Quartus
  // adds read-during-write pass-through logic to match RTL semantics it
  // cannot prove are unreachable -- six Warning (276020) and the logic to go
  // with it.  This states the design fact; it does not silence the warning.
  (* ramstyle = "no_rw_check" *)
  reg [15:0] tdat [0:(1<<TIDX)*4-1];
  (* ramstyle = "no_rw_check" *)
  reg [6:0]  ttag [0:(1<<TIDX)-1];
  reg        tval [0:(1<<TIDX)-1];
  reg [15:0] tdat_q;
  reg [6:0]  ttag_q;
  reg        tval_q;
  reg        thit;
  integer    ti;

  wire [TIDX-1:0] cidx = tile[TIDX-1:0];
  wire [6:0]      ctag = tile[11:TIDX];

  // Low on a tile-number hit as well as on a cached line, by construction.
  assign rom_req  = ((st == S_ROM) || (st == S_WAIT)) && !thit;
  assign rom_hold = (st == S_WAIT) && (k != 2'd3);

  // ---- fg's wasted byte, reclaimed --------------------------------------
  //
  // byte_off is tile*32 + k*8 + py, so byte_off[0] IS py[0]: one 16-bit read
  // returns row py in one half and row py^1 in the other.  That pairing comes
  // straight from MAME's fg8x8x4_layout, whose y offsets are {0*8 .. 7*8} --
  // consecutive rows are consecutive BYTES.
  //
  // The old code used one half and threw the other away, then fetched the
  // same word again on the next line.  fg therefore asked for 160 of the
  // ~400 SDRAM reads a line needs while sitting at the LOWEST priority of the
  // three layers: both the biggest consumer and the one being starved (row
  // 41, 95 lines dropped a frame; row 51, 1 tile finished of the 39 a line
  // needs).
  //
  // An even py now caches the odd row's byte, and the odd line spends no
  // SDRAM at all.  The pairing is always inside one character row -- py even
  // means py in {0,2,4,6} and py+1 in {1,3,5,7} -- so the map row and the
  // tile numbers are identical and there is nothing to invalidate.
  //
  // cache_y guards the one real hazard: arriving at an odd line without
  // having rendered its even partner, which happens on the first visible line
  // and after a dropped line.  Then the cache holds another row's bytes and
  // the fetch has to happen after all.
  reg  [7:0] fgc [0:255];
  reg  [7:0] fgc_q;                      // the RAM's registered output
  always @(posedge clk) fgc_q <= fgc[{t, k}];
  reg  [8:0] cache_y;
  reg        cache_ok;
  //
  // ---- and why it is off when the screen is flipped ---------------------
  //
  // Everything above assumes an even py line is followed by its ODD partner:
  // it caches the byte for py^1 = py+1 and the next line spends no SDRAM.
  // Under flip the lines arrive with screen_y DECREASING, so the partner
  // arrives FIRST and the pairing runs backwards.
  //
  // That is not a miss, it is a wrong hit.  `cache_y <= screen_y - 1` records
  // "the line that just finished", which under flip is screen_y + 1 -- and
  // the two errors cancel in the guard: `screen_y == cache_y + 1` comes out
  // TRUE on the next line, handing it a byte belonging to py+2.  Measured on
  // hardware 2026-09-03: the flipped frame was the exact 180-degree rotation
  // of the unflipped one on every EVEN row and wrong by two rows on every
  // odd one -- 586 pixels of 76,800, all of them fg (DEBUG_LOG A45).
  //
  // Turning the cache off under flip is correct rather than clever: without
  // it every line fetches its own byte at byte_off[0] = py[0], which does not
  // care what order the lines arrive in.  The price is fg's SDRAM reads
  // doubling in a mode nobody plays in, and whether that still finishes 272
  // lines is a measurement, not an argument -- see the STATUS entry.
  //
  // Reversing the pairing instead (fill on odd py, use on even, cache_y + 1)
  // would keep the bandwidth and is the fix to make if flipped drops lines.
  // It is not the fix to make first, because this module is in the critical
  // bandwidth path that criterion 1 rests on and there is no simulator here.
  wire       use_cache = !flip && py[0] && cache_ok
                         && (screen_y == cache_y + 9'd1);

  // ---------------------------------------------------------------------
  // Pixel assembly.
  //
  // Pair p is b[p]; the EVEN pixel of the pair takes bits 6,4,2,0 and the
  // ODD one bits 7,5,3,1, MSB of the pixel first.  Getting this pair order
  // backwards is the failure recorded in the header.
  // ---------------------------------------------------------------------
  wire [1:0] pr  = bx[2:1];
  wire       odd = bx[0];
  wire [7:0] pb  = b[pr];
  wire [3:0] pen = odd ? {pb[7], pb[5], pb[3], pb[1]}
                       : {pb[6], pb[4], pb[2], pb[0]};

  wire [9:0] px = {4'd0, t} * 10'd8 + {7'd0, bx};

  integer i;
  always @(posedge clk) begin
    wr_e <= 1'b0;

    if (rst) begin
      st <= S_IDLE; t <= 6'd0; k <= 2'd0; wsel <= 1'b0;
      dbg_rows_done <= 16'd0; dbg_overrun <= 16'd0;
      dbg_min_t <= 6'h3F;
      row <= 5'd0; py <= 3'd0; tile <= 12'd0; colour <= 4'd0;
      cache_ok <= 1'b0; cache_y <= 9'd0;
      bx <= 3'd0; map_w0 <= 16'd0; wr_a <= 10'd0; wr_d <= 8'd0;
      for (i = 0; i < 4; i = i + 1) b[i] <= 8'd0;
    end else begin
      if (line_start) begin
        if (st != S_IDLE && st != S_DONE) begin
          dbg_overrun <= dbg_overrun + 16'd1;
          if (t < dbg_min_t) dbg_min_t <= t;
        end
        else if (st == S_DONE)            dbg_rows_done <= dbg_rows_done + 16'd1;

        // A line that completes with an even py leaves a usable cache for
        // the line after it.  Recorded on the line that FILLED it, so an
        // overrun line -- which never reached the last tile -- cannot leave a
        // half-filled cache marked good.
        // At this point `py` still describes the line that just finished
        // while `screen_y` has already advanced to the new one, so the line
        // that filled the cache is screen_y - 1.  Mixing the two was the
        // first cut of this and it recorded a y that never existed.
        if (st == S_DONE && !py[0]) begin
          cache_ok <= 1'b1;
          cache_y  <= screen_y - 9'd1;
        end else if (!py[0]) begin
          cache_ok <= 1'b0;               // an overrun line leaves no cache
        end

        wsel <= ~wsel;
        row  <= screen_y[7:3];
        py   <= screen_y[2:0];
        t    <= 6'd0;
        thit <= 1'b0;
        // D17.  py has changed, so every cached row is for the wrong line.
        for (ti = 0; ti < (1<<TIDX); ti = ti + 1) tval[ti] <= 1'b0;
        k    <= 2'd0;
        st   <= S_MAP0;
      end else begin
        case (st)
          S_IDLE: ;
          S_MAP0: st <= S_MAP1;          // dpram latency on word 0
          S_MAP1: begin map_w0 <= map_data; st <= S_MAP2; end
          S_MAP2: st <= S_LATCH;         // dpram latency on word 1
          S_LATCH: begin
            tile   <= {map_data[3:0], map_w0[7:0]};
            colour <= map_data[7:4];
            st     <= use_cache ? S_CA : S_TCHK;
          end

          // The cached read is REGISTERED.  Quartus infers fgc as an
          // altsyncram (Simple Dual Port, 256x8, read-during-write None), so
          // the data for an address presented in one clock is available in
          // the next -- the same rule sf_sprite.sv states for sf_dpram.  The
          // first cut assumed a combinational array and read one clock early.
          //
          // S_CA presents {t,k}; S_CD latches it and advances.  Eight clocks
          // a tile instead of four, which still leaves a cached line at about
          // 800 of the 3584 clocks in a line.
          S_CA: st <= S_CD;

          S_CD: begin
            b[k] <= fgc_q;
            if (k == 2'd3) begin
              k  <= 2'd0;
              bx <= 3'd0;
              st <= S_BLIT;
            end else begin
              k  <= k + 2'd1;
              st <= S_CA;
            end
          end

          S_TCHK: begin
            ttag_q <= ttag[cidx];
            tval_q <= tval[cidx];
            st     <= S_THIT;
          end

          S_THIT: begin
            thit <= tval_q && (ttag_q == ctag);
            st   <= S_ROM;
          end

          S_ROM: begin
            tdat_q <= tdat[{cidx, k}];
            st     <= thit ? S_TRD : S_WAIT;
          end

          // Exactly what S_WAIT does with rom_data, including filling the
          // byte-pair cache -- the next line still needs it, and a tile-number
          // hit must not quietly stop feeding it.
          S_TRD: begin
            b[k] <= byte_off[0] ? tdat_q[7:0] : tdat_q[15:8];
            if (!byte_off[0]) fgc[{t, k}] <= tdat_q[7:0];
            if (k == 2'd3) begin
              k  <= 2'd0;
              bx <= 3'd0;
              st <= S_BLIT;
            end else begin
              k  <= k + 2'd1;
              st <= S_ROM;
            end
          end

          S_WAIT: if (rom_ack) begin
            // one byte of the word; which half depends on the low bit of the
            // byte address, and consecutive y are the two halves
            b[k] <= byte_off[0] ? rom_data[7:0] : rom_data[15:8];
            // ...and the half NOT used is the next row of this same tile.
            // Kept only on an even py, which is the half that pairs forward.
            if (!byte_off[0]) fgc[{t, k}] <= rom_data[7:0];
            tdat[{cidx, k}] <= rom_data;         // D17: fill as it arrives
            if (k == 2'd3) begin
              // Valid only once all four are in: a tile cut off by the line
              // ending must not be served as complete at the next py.
              ttag[cidx] <= ctag;
              tval[cidx] <= 1'b1;
              k  <= 2'd0;
              bx <= 3'd0;
              st <= S_BLIT;
            end else begin
              k  <= k + 2'd1;
              st <= S_ROM;
            end
          end

          S_BLIT: begin
            if (px < H_VISIBLE[9:0]) begin
              wr_a <= {wsel, px[8:0]};
              wr_d <= {colour, pen};
              wr_e <= 1'b1;
            end
            if (bx == 3'd7) begin
              bx <= 3'd0;
              if (t == N_TILES[5:0] - 6'd1) st <= S_DONE;
              else begin
                t  <= t + 6'd1;
                st <= S_MAP0;
              end
            end else begin
              bx <= bx + 3'd1;
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
