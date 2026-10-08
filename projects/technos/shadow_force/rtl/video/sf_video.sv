//============================================================================
//  Shadow Force -- video mixer
//
//  Layer order, from docs/HARDWARE.md section 10 (MAME's screen_update):
//
//      bg1        opaque, drawn first
//      bg0        transparent on pen 0, marks priority bit 1
//      sprites    a sprite with word4[6] set goes BEHIND bg0
//      fg         transparent on pen 0, on top of everything
//
//  bg1, bg0 and fg are built.  Sprites are not, and they sit between bg0 and
//  fg, so adding them is a local change to the mix rather than a rewrite.
//
//  bg0 and bg1 SHARE the bg RAM's single second port and both fetch during
//  the same line, so there is a request/grant mux below.  bg1 wins ties.
//
//  ---- the pipeline fits inside one pixel ---------------------------------
//
//  The line buffer answers one clock after hcnt changes and the palette RAM
//  one clock after that.  The board runs at 8x the 7 MHz pixel clock, so
//  both land with six clocks to spare and no pixel-level delay line is
//  needed anywhere.  That is a real benefit of the 56 MHz choice in
//  DECISIONS D1 and it is worth not throwing away: if a future layer needs
//  a third lookup it still fits, but a fourth would not.
//
//  ---- brightness ---------------------------------------------------------
//
//  Register 1D000D scales every pen.  MAME implements it by rewriting all
//  0x4000 palette entries' contrast; on hardware it is one register feeding
//  the DACs, so it is a multiply on the way out.  A core that ignores it is
//  too bright during fades.
//============================================================================
`default_nettype none

module sf_video #(
    parameter int H_VISIBLE = 320,
    parameter int V_START   = 8,
    parameter int V_VISIBLE = 240,
    parameter int V_TOTAL   = 272
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,

    input  wire [8:0]  hcnt,
    input  wire [8:0]  vcnt,

    // Flip screen -- 1C000A bit 0, `flip_screen_set(data & 0x01)` in MAME.
    //
    // Root CLAUDE.md: a horizontal game does not get a flip built for it, and
    // the exception is a board whose own DIP block carries the switch.  This
    // one does -- shadfrce.cpp:697, SW1:6 -- so it is built.
    //
    // On the PCB this is a cabinet-orientation switch and it inverts the video
    // COUNTERS, so every layer flips together.  Neither reference does that:
    // MAME's helper flips the three tilemaps and `draw_sprites` never consults
    // it, so its sprites stay put; FBNeo's `case 0x1C000B:` holds a comment and
    // nothing else.  They disagree, which by root CLAUDE.md 12.0 is the finding
    // -- neither is hardware truth here, and the counter inversion below is
    // INFERRED.  MAME_AUDIT 6 carries the row.
    //
    // bg0, bg1 and fg need no change of their own: each uses `hcnt` only to
    // index its line buffer and `vcnt` only through `next_line`, so mirroring
    // what they are handed mirrors what they draw.  The sprite engine cannot
    // be flipped this way -- it also uses `hcnt` as BEAM PROGRESS, to keep its
    // erase behind the read -- so it takes the raw count and a `flip` input.
    input  wire        flip_screen,
    input  wire        hblank,
    input  wire        vblank,
    input  wire        line_start,

    input  wire        video_enable,
    input  wire [7:0]  screen_brt,

    input  wire [8:0]  bg0_scrollx,
    input  wire [8:0]  bg0_scrolly,
    input  wire [8:0]  bg1_scrollx,
    input  wire [8:0]  bg1_scrolly,

    // --- bg RAM, B port.  ONE port, TWO fetchers -- muxed below. ------------
    output wire [12:0] map_addr,
    input  wire [15:0] map_data,

    // --- the CPU's write to that RAM, for the tear counter ------------------
    input  wire        cpu_map_we,
    input  wire [12:0] cpu_map_a,

    // --- palette RAM, B port ------------------------------------------------
    output wire [13:0] pal_addr,
    input  wire [15:0] pal_data,

    // --- fg map RAM, B port -------------------------------------------------
    output wire [11:0] fgmap_addr,
    input  wire [15:0] fgmap_data,

    // --- tile ROM: bg1 and bg0 have separate arbiter clients ----------------
    output wire [24:0] rom_addr,
    input  wire [15:0] rom_data,
    output wire        rom_req,
    output wire        rom_hold,
    input  wire        rom_ack,
    output wire [24:0] rom0_addr,
    input  wire [15:0] rom0_data,
    output wire        rom0_req,
    output wire        rom0_hold,
    input  wire        rom0_ack,
    input  wire [24:0] tile_base_w,

    // --- char ROM, its own arbiter client -----------------------------------
    output wire [24:0] crom_addr,
    input  wire [15:0] crom_data,
    output wire        crom_req,
    output wire        crom_hold,
    input  wire        crom_ack,
    input  wire [24:0] chars_base_w,

    // --- sprites -----------------------------------------------------
    output wire [11:0] spr_addr,
    input  wire [15:0] spr_data,
    output wire [24:0] srom_addr,
    input  wire [15:0] srom_data,
    output wire        srom_req,
    output wire        srom_hold,
    input  wire        srom_ack,
    input  wire [24:0] spr_base_w,

    // --- out ------------------------------------------------------------------
    output wire [23:0] rgb,

    // --- observability --------------------------------------------------------
    output wire [15:0] dbg_rows_done,
    output wire [15:0] dbg_overrun,
    output wire [15:0] dbg_fg_rows,
    output wire [15:0] dbg_fg_overrun,
    output wire [5:0]  dbg_fg_min_t,
    output wire [15:0] dbg_spr_rows,
    output wire [15:0] dbg_spr_overrun,
    output wire [15:0] dbg_spr_blits,
    output wire [7:0]  dbg_spr_n_act,
    output wire [15:0] dbg_spr_prescans,
    output wire [15:0] dbg_spr_w0_or,
    input  wire        copy_done,
    output wire [15:0] dbg_bg0_overrun,
    output wire [15:0] dbg_bg0_rows,
    output wire [15:0] dbg_bg0_tear
);

  // ---------------------------------------------------------------------
  // The mirrored counters (flip screen)
  //
  // A layer's line buffer holds SOURCE columns and is read at `hcnt`, one
  // register later, so the pixel shown at beam position h is source column h.
  // Mirroring is therefore just  h -> H_VISIBLE-1-h  on the way in.
  //
  // The vertical one is not that, because a renderer works a line AHEAD: it
  // computes `next_line = vcnt+1` and then `screen_y = next_line - V_START`.
  // What has to come out mirrored is `screen_y`, not `vcnt`, so the constant
  // absorbs both the +1 and the V_START:
  //
  //     want   screen_y(flipped) = V_VISIBLE-1 - screen_y(normal)
  //     have   screen_y          = vcnt_r + 1 - V_START
  //     so     vcnt_r            = 2*V_START + V_VISIBLE - 3 - vcnt
  //
  // which is 253 - vcnt here.  Getting it wrong by one shifts every layer a
  // line, which reads as a scroll bug -- the warning sf_tilemap.sv:157 already
  // carries about the unflipped case.
  //
  // `next_line`'s wrap test (`vcnt == V_TOTAL-1`) cannot fire on the mirrored
  // value: it would need vcnt = -18.  The lines that lose their wrap are all
  // in blanking, where what a renderer puts in the buffer is never displayed.
  //
  // `line_start` stays RAW.  It is the trigger that swaps the buffers, not a
  // coordinate, and flipping it would move the swap into the visible line.
  wire [8:0] hcnt_r = flip_screen ? (H_VISIBLE[8:0] - 9'd1 - hcnt) : hcnt;
  wire [8:0] vcnt_r = flip_screen
                    ? (9'(2*V_START + V_VISIBLE - 3) - vcnt) : vcnt;

  // ---------------------------------------------------------------------
  // bg1 -- 32x32 of 16x16, one word per tile, opaque
  // ---------------------------------------------------------------------
  wire [13:0] bg1_pal;
  wire        bg1_opaque;   // unused while bg1 is the only layer: it is the
                            // backmost one and MAME draws it opaque

  wire [12:0] bg1_map_a, bg0_map_a;
  wire        bg1_map_req, bg0_map_req;
  wire        bg1_map_gnt, bg0_map_gnt;

  sf_tilemap #(
      .MAP_BASE ('h1000),          // 102000-1027FF inside the bg RAM block
      .TWO_WORD (1'b0),
      .H_VISIBLE(H_VISIBLE),
      .V_START  (V_START),
      .V_TOTAL  (V_TOTAL)
  ) u_bg1 (
      .clk(clk), .rst(rst), .ce_pix(ce_pix),
      .hcnt(hcnt_r), .vcnt(vcnt_r), .line_start(line_start),
      .scrollx(bg1_scrollx), .scrolly(bg1_scrolly),
      .map_addr(bg1_map_a), .map_data(map_data),
      .map_req(bg1_map_req), .map_gnt(bg1_map_gnt),
      .rom_addr(rom_addr), .rom_data(rom_data),
      .rom_req(rom_req), .rom_ack(rom_ack), .rom_hold(rom_hold),
      .tile_base_w(tile_base_w),
      .pal_index(bg1_pal), .opaque(bg1_opaque),
      .cpu_map_we(cpu_map_we), .cpu_map_a(cpu_map_a),
      .dbg_rows_done(dbg_rows_done), .dbg_overrun(dbg_overrun),
      .dbg_tear()                  // TWO_WORD=0: one word, cannot tear
  );

  // ---------------------------------------------------------------------
  // bg0 -- 32x32 of 16x16, TWO words per tile, transparent on pen 0, flips
  // ---------------------------------------------------------------------
  wire [13:0] bg0_pal;
  wire        bg0_opaque;

  sf_tilemap #(
      .MAP_BASE ('h0000),          // 100000-100FFF inside the bg RAM block
      .TWO_WORD (1'b1),
      .H_VISIBLE(H_VISIBLE),
      .V_START  (V_START),
      .V_TOTAL  (V_TOTAL)
  ) u_bg0 (
      .clk(clk), .rst(rst), .ce_pix(ce_pix),
      .hcnt(hcnt_r), .vcnt(vcnt_r), .line_start(line_start),
      .scrollx(bg0_scrollx), .scrolly(bg0_scrolly),
      .map_addr(bg0_map_a), .map_data(map_data),
      .map_req(bg0_map_req), .map_gnt(bg0_map_gnt),
      .rom_addr(rom0_addr), .rom_data(rom0_data),
      .rom_req(rom0_req), .rom_ack(rom0_ack), .rom_hold(rom0_hold),
      .tile_base_w(tile_base_w),
      .pal_index(bg0_pal), .opaque(bg0_opaque),
      .cpu_map_we(cpu_map_we), .cpu_map_a(cpu_map_a),
      .dbg_rows_done(dbg_bg0_rows), .dbg_overrun(dbg_bg0_overrun),
      .dbg_tear(dbg_bg0_tear)
  );

  // ---------------------------------------------------------------------
  // Map-port mux.  One B port, two fetchers, both running in the same line.
  //
  // bg1 wins a tie.  It is the BACKMOST layer and opaque, so a line it fails
  // to fetch is a hole in the picture rather than a missing detail -- and its
  // entries are one word, so it holds the port for half as long per tile.
  // Each fetcher holds its address until granted, so a loss is a stall, not
  // a wrong read.
  //
  // **Absolute priority cannot starve bg0, and that was simulated rather
  // than argued.**  Stepping this handshake for a full 21-tile line: both
  // layers finish in 1071 of a line's 3584 clocks and bg0 waits for the port
  // for exactly ONE clock in the whole line.  bg1 requests for a single
  // clock per tile and then works for tens, so the port is idle almost all
  // the time.  No deadlock, no starvation.
  //
  // That simulation covers THIS mux only.  Whether all three layers fit
  // through the SDRAM arbiter is a different and harder question --
  // DECISIONS D4, and it is not yet answered.
  // ---------------------------------------------------------------------
  assign bg1_map_gnt = bg1_map_req;
  assign bg0_map_gnt = bg0_map_req & ~bg1_map_req;
  assign map_addr    = bg1_map_req ? bg1_map_a : bg0_map_a;

  // ---------------------------------------------------------------------
  // fg -- 64x32 of 8x8, two words per tile, transparent on pen 0, no scroll
  // ---------------------------------------------------------------------
  wire [13:0] fg_pal;
  wire        fg_opaque;

  sf_fgmap #(
      .H_VISIBLE(H_VISIBLE), .V_START(V_START), .V_TOTAL(V_TOTAL)
  ) u_fg (
      .clk(clk), .rst(rst), .ce_pix(ce_pix),
      .hcnt(hcnt_r), .vcnt(vcnt_r), .line_start(line_start),
      .flip(flip_screen),
      .map_addr(fgmap_addr), .map_data(fgmap_data),
      .rom_addr(crom_addr), .rom_data(crom_data),
      .rom_req(crom_req), .rom_ack(crom_ack), .rom_hold(crom_hold),
      .chars_base_w(chars_base_w),
      .pal_index(fg_pal), .opaque(fg_opaque),
      .dbg_rows_done(dbg_fg_rows), .dbg_overrun(dbg_fg_overrun),
      .dbg_min_t(dbg_fg_min_t)
  );

  // ---------------------------------------------------------------------
  // Layer mix.
  //
  // MAME's order is bg1 (opaque), bg0, sprites, fg (on top).  bg0 and the
  // sprites are not built, so this is bg1 with fg over it -- and fg really is
  // last, so adding the middle two later does not disturb this pair.
  // ---------------------------------------------------------------------
  // MAME: bg1 (opaque) -> bg0 (trans) -> sprites -> fg (trans, on top).
  // Sprites are the only missing layer now, and they sit between bg0 and fg.
  // MAME: bg1 (opaque) -> bg0 -> sprites -> fg on top, with a sprite whose
  // w4[6] is set hidden wherever bg0 drew.  That last clause is why the line
  // buffer carries the priority bit instead of resolving it at blit time: a
  // suppressed sprite still CLAIMS its pixel in MAME (PRIORITY = 31 is written
  // on the not-drawn path too), so the decision has to happen here, against
  // this pixel's bg0, and not earlier.
  wire spr_show = spr_opaque & ~(spr_pri & bg0_opaque);

  assign pal_addr = fg_opaque  ? fg_pal
                  : spr_show   ? spr_pal
                  : bg0_opaque ? bg0_pal
                               : bg1_pal;

  // ---------------------------------------------------------------------
  // Sprites
  // ---------------------------------------------------------------------
  wire [13:0] spr_pal;
  wire        spr_opaque, spr_pri;

  sf_sprite #(.H_VISIBLE(H_VISIBLE), .V_VISIBLE(V_VISIBLE), .V_TOTAL(V_TOTAL)) u_spr (
      .clk(clk), .rst(rst), .ce_pix(ce_pix),
      // raw hcnt: this module also uses it as beam progress
      .hcnt(hcnt), .vcnt(vcnt_r), .line_start(line_start),
      .flip(flip_screen),
      .copy_done(copy_done),
      .spr_addr(spr_addr), .spr_data(spr_data),
      .rom_addr(srom_addr), .rom_data(srom_data),
      .rom_req(srom_req),   .rom_ack(srom_ack), .rom_hold(srom_hold),
      .spr_base_w(spr_base_w),
      .pal_index(spr_pal), .opaque(spr_opaque), .pri(spr_pri),
      .dbg_rows_done(dbg_spr_rows), .dbg_overrun(dbg_spr_overrun),
      .dbg_blits(dbg_spr_blits), .dbg_n_act(dbg_spr_n_act),
      .dbg_prescans(dbg_spr_prescans), .dbg_w0_or(dbg_spr_w0_or)
  );

  // ---------------------------------------------------------------------
  // Palette -> RGB.  Format is xBGR555: R = [4:0], G = [9:5], B = [14:10].
  // The low three bits of each channel are the top three of the same field,
  // which is the usual 5-to-8 expansion and keeps full white at 0xFF.
  // ---------------------------------------------------------------------
  wire [7:0] r8 = {pal_data[4:0],   pal_data[4:2]};
  wire [7:0] g8 = {pal_data[9:5],   pal_data[9:7]};
  wire [7:0] b8 = {pal_data[14:10], pal_data[14:12]};

  // MAME computes `pen * (data / 255.0)`.  The obvious hardware form,
  // `(pen * data) >> 8`, is `pen * data / 256` -- so at data = 255 it gives
  // 254 where MAME gives 255, and EVERY colour is 0.4 % dark on every frame.
  //
  // `pen * (data + 1) >> 8` stood here as "exact at both ends, within one
  // LSB in between" -- and the in-between was one LSB HIGH on 1,892 of the
  // 8,192 (pen, data) pairs, which is every fade frame (19,558 pixels off on
  // the golden t136 frame).  MAME is trunc(pen * float(data/255)), which is
  // floor(pen*data/255) on all 8,192 pairs (checked exhaustively), and
  //     floor(x/255) == (x + (x>>8) + 1) >> 8      for every x <= 65025
  // (also checked exhaustively).  Two adders, no divider, exact.
  wire [15:0] rp = r8 * screen_brt;
  wire [15:0] gp = g8 * screen_brt;
  wire [15:0] bp = b8 * screen_brt;
  wire [16:0] rm = {1'b0, rp} + {9'd0, rp[15:8]} + 17'd1;
  wire [16:0] gm = {1'b0, gp} + {9'd0, gp[15:8]} + 17'd1;
  wire [16:0] bm = {1'b0, bp} + {9'd0, bp[15:8]} + 17'd1;

  // video_enable is 1D0006 bit 3.  MAME fills the frame with the black pen
  // when it is clear, so a core that ignores it shows a frame the real board
  // would have blanked.
  assign rgb = (video_enable && !hblank && !vblank)
             ? {rm[15:8], gm[15:8], bm[15:8]}
             : 24'h000000;

endmodule

`default_nettype wire
