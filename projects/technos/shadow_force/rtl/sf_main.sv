//============================================================================
//  Shadow Force -- main CPU board: 68000, address decode, board RAM, I/O
//
//  Every address here comes from docs/HARDWARE.md section 3, which is taken
//  from MAME's shadfrce main_map.  Two things are easy to get wrong and are
//  called out where they happen:
//
//    * 1D000C and 1D000D are two different byte-wide registers inside one
//      word -- sound latch and screen brightness.  A decode that ignores
//      UDS/LDS writes the brightness every time the game sends a sound
//      command.
//
//    * the input words are scrambled across seven sources (section 6).  A
//      wrong bit there does not read as an input bug, it reads as the game
//      booting and then jumping to the end.
//
//  Program ROM is NOT here.  It reaches the board over the neutral rom_*
//  port so that MiSTer can back it with SDRAM and Pocket with its own
//  memory, per root CLAUDE.md section 4.  Board RAM is on the board, because
//  the board owns its own arbitration.
//============================================================================
`default_nettype none

module sf_main #(
    // MAME raises the polled vblank flag at line 247 with the comment
    // "-1 is an hack needed to avoid deadlocks", while raising the vblank
    // *interrupt* at 248.  247 is what is known to run; 248 is the hardware
    // hypothesis.  docs/MAME_NOTES.md section 1.2, docs/DEBUG_LOG.md A1.
    parameter int VBL_FLAG_LINE = 247
) (
    input  wire        clk,          // 56.000 MHz system clock
    input  wire        rst,
    input  wire        ce_en,        // global enable (low during download)
    input  wire        cpu_rst,      // hold the CPU (download)

    // --- program ROM, neutral interface ------------------------------------
    output wire [19:1] rom_addr,     // 1 MB region, word address
    input  wire [15:0] rom_data,
    output wire        rom_rd,
    input  wire        rom_ack,

    // --- board RAM, CPU side of each dual-port block ------------------------
    output wire [12:0] bg_addr,      // 100000-103FFF, 8 K words
    output wire [15:0] bg_din,
    input  wire [15:0] bg_dout,
    output wire [1:0]  bg_we,

    output wire [11:0] fg_addr,      // 140000-141FFF, 4 K words
    output wire [15:0] fg_din,
    input  wire [15:0] fg_dout,
    output wire [1:0]  fg_we,

    output wire [11:0] spr_addr,     // 142000-143FFF, 4 K words
    output wire [15:0] spr_din,
    input  wire [15:0] spr_dout,
    output wire [1:0]  spr_we,

    output wire [13:0] pal_addr,     // 180000-187FFF, 16 K words
    output wire [15:0] pal_din,
    input  wire [15:0] pal_dout,
    output wire [1:0]  pal_we,

    // --- video registers ----------------------------------------------------
    output reg  [8:0]  bg0_scrollx,
    output reg  [8:0]  bg0_scrolly,
    output reg  [8:0]  bg1_scrollx,
    output reg  [8:0]  bg1_scrolly,
    output reg         flip_screen,
    output reg         video_enable,
    output reg  [7:0]  screen_brt,

    // --- video timing in ----------------------------------------------------
    input  wire [8:0]  vcnt,
    input  wire [8:0]  hcnt,
    input  wire        ce_pix,

    // --- sound --------------------------------------------------------------
    output reg  [7:0]  sound_latch,
    output reg         sound_latch_we,

    // --- inputs, all active low --------------------------------------------
    input  wire [7:0]  in_p1,
    input  wire [7:0]  in_p2,
    input  wire [7:0]  in_extra,
    input  wire [7:0]  in_other,
    input  wire [7:0]  in_system,
    input  wire [7:0]  in_misc,
    input  wire [7:0]  dsw1,
    input  wire [7:0]  dsw2,

    // --- observability ------------------------------------------------------
    output wire [23:1] dbg_addr,
    output wire        dbg_rd,
    output wire        dbg_wr,
    output wire        dbg_ack,
    output wire [15:0] dbg_din,
    output wire [15:0] dbg_dout,
    output wire [31:0] dbg_d7,
    output wire        dbg_halted_n,
    output wire [2:0]  dbg_irq,
    output reg  [15:0] dbg_irq_count,
    // Level-2 RAISES, not edges.  irq2 is a level held until the CPU writes
    // 1D0002, so an edge counter reads 0 both when the source never fires and
    // when it fires every 16 lines but is never acknowledged -- opposite
    // states, same number.  That cost two investigations (DEBUG_LOG A16, A20).
    output reg  [15:0] dbg_irq2_count,
    // ...and the acknowledgements, so "who stopped" is answerable directly.
    output reg  [15:0] dbg_irq2_ack,
    // 1D0016.  A one-clock strobe, not a count: the counting is sf_top's,
    // because the timeout is measured in FRAMES and this module has no frame.
    // What used to be here was a free-running pet count, and it answered its
    // question long ago -- rows 12-15 and the reads-per-line say whether the
    // CPU is alive, and they say it without wrapping (DEBUG_LOG A11).
    output reg         wdog_pet
);

  // ---------------------------------------------------------------------
  // 68000
  // ---------------------------------------------------------------------
  wire [23:1] a;
  wire [15:0] cpu_dout;
  reg  [15:0] cpu_din;
  wire        cpu_rd, cpu_wr, uds_n, lds_n, iack;
  reg         cpu_ack;
  wire [2:0]  ipl_n;

  sf_m68k #(.CLK_DIV(4)) u_cpu (
      .clk      (clk),
      .rst      (rst),
      .cpu_rst  (cpu_rst),
      .ce_en    (ce_en),
      .addr     (a),
      .dout     (cpu_dout),
      .din      (cpu_din),
      .rd       (cpu_rd),
      .wr       (cpu_wr),
      .uds_n    (uds_n),
      .lds_n    (lds_n),
      .ack      (cpu_ack),
      .ipl_n    (ipl_n),
      .fc       (),
      .dbg_d7   (dbg_d7),
      .as_n     (),
      .halted_n (dbg_halted_n),
      .iack     (iack)
  );

  wire [1:0] be = {~uds_n, ~lds_n};      // byte enables: [1]=high, [0]=low
  wire [1:0] we = cpu_wr ? be : 2'b00;

  // ---------------------------------------------------------------------
  // Address decode
  //
  // Decoded exactly as MAME lists the ranges.  Whether the real board mirrors
  // these regions across the unlisted address space is UNVERIFIED, so
  // unmapped reads return 0xFFFF rather than aliasing onto something.
  // ---------------------------------------------------------------------
  wire sel_rom  = (a[23:20] == 4'h0);                        // 000000-0FFFFF
  wire sel_bg   = (a[23:16] == 8'h10) && (a[15:14] == 2'b00);// 100000-103FFF
  wire sel_fg   = (a[23:16] == 8'h14) && (a[15:13] == 3'b000);//140000-141FFF
  wire sel_spr  = (a[23:16] == 8'h14) && (a[15:13] == 3'b001);//142000-143FFF
  wire sel_pal  = (a[23:16] == 8'h18) && (a[15] == 1'b0);    // 180000-187FFF
  wire sel_vreg = (a[23:16] == 8'h1C) && (a[15:4] == 12'd0); // 1C0000-1C000F
  wire sel_creg = (a[23:16] == 8'h1D) && (a[15:5] == 11'd0); // 1D0000-1D001F
  wire sel_inp  = (a[23:16] == 8'h1D) && (a[15:5] == 11'd1)  // 1D0020-1D0027
                                     && (a[4:3] == 2'b00);
  wire sel_work = (a[23:16] == 8'h1F);                       // 1F0000-1FFFFF

  // ---------------------------------------------------------------------
  // Work RAM -- 64 K, the largest single block on the board
  // ---------------------------------------------------------------------
  wire [15:0] work_dout;
  sf_ram #(.AW(15)) u_work (
      .clk (clk),
      .addr(a[15:1]),
      .din (cpu_dout),
      .we  (sel_work ? we : 2'b00),
      .dout(work_dout)
  );

  // ---------------------------------------------------------------------
  // CPU side of the dual-port video RAM blocks
  // ---------------------------------------------------------------------
  assign bg_addr  = a[13:1];
  assign bg_din   = cpu_dout;
  assign bg_we    = sel_bg  ? we : 2'b00;

  assign fg_addr  = a[12:1];
  assign fg_din   = cpu_dout;
  assign fg_we    = sel_fg  ? we : 2'b00;

  assign spr_addr = a[12:1];
  assign spr_din  = cpu_dout;
  assign spr_we   = sel_spr ? we : 2'b00;

  assign pal_addr = a[14:1];
  assign pal_din  = cpu_dout;
  assign pal_we   = sel_pal ? we : 2'b00;

  // ---------------------------------------------------------------------
  // Program ROM
  // ---------------------------------------------------------------------
  assign rom_addr = a[19:1];
  assign rom_rd   = cpu_rd & sel_rom;

  // ---------------------------------------------------------------------
  // A write must take effect exactly once even though cpu_wr is held until
  // ack.  wr_taken gates the register file after the first accepted cycle.
  // ---------------------------------------------------------------------
  reg wr_taken;
  always @(posedge clk) begin
    if (rst)                  wr_taken <= 1'b0;
    else if (!cpu_wr)         wr_taken <= 1'b0;
    else if (ce_en && cpu_wr) wr_taken <= 1'b1;
  end
  wire wr_stb = ce_en & cpu_wr & ~wr_taken;

  // ---------------------------------------------------------------------
  // Interrupts
  //
  //   level 1  raster compare        acknowledged by a write to 1D0004
  //   level 2  every 16 scanlines    acknowledged by a write to 1D0002
  //   level 3  vblank at line 248    acknowledged by a write to 1D0000
  //
  // MAME clears `offset ^ 3`, so the word at 1D0000 acks level 3 and the word
  // at 1D0004 acks level 1.  a[2:1] is that offset.
  //
  // The raster compare is the one interrupt whose real behaviour is unknown:
  // MAME increments the compare register itself on every match, which no
  // plausible hardware register does.  docs/MAME_NOTES.md section 1.1.  A
  // straight compare is implemented here and the difference is expected.
  // ---------------------------------------------------------------------
  reg        irq1, irq2, irq3;
  reg        irqs_enable, raster_arm, prev_bit2;
  reg [8:0]  raster_line;

  wire line_tick = ce_pix && (hcnt == 9'd0);

  assign ipl_n = irq3 ? 3'b100 :      // level 3
                 irq2 ? 3'b101 :      // level 2
                 irq1 ? 3'b110 :      // level 1
                        3'b111;

  always @(posedge clk) begin
    wdog_pet <= 1'b0;          // one clock, like sound_latch_we below
    if (rst) begin
      irq1 <= 1'b0; irq2 <= 1'b0; irq3 <= 1'b0;
      irqs_enable <= 1'b0;
      raster_arm  <= 1'b0;
      prev_bit2   <= 1'b0;
      raster_line <= 9'd0;
      video_enable <= 1'b0;
      dbg_irq_count <= 16'd0;
      dbg_irq2_count <= 16'd0;
      dbg_irq2_ack   <= 16'd0;
      wdog_pet      <= 1'b0;
    end else begin
      // --- raise ---------------------------------------------------------
      if (line_tick) begin
        if (irqs_enable && (vcnt == 9'd248)) begin
          irq3 <= 1'b1;
          dbg_irq_count <= dbg_irq_count + 16'd1;
        end
        if (irqs_enable && (vcnt[3:0] == 4'd0)) begin
          irq2 <= 1'b1;
          dbg_irq2_count <= dbg_irq2_count + 16'd1;
        end
        if (raster_arm  && (vcnt == raster_line)) irq1 <= 1'b1;
      end

      // --- control and acknowledge ---------------------------------------
      if (wr_stb && sel_creg) begin
        case (a[4:1])
          4'd0: irq3 <= 1'b0;                        // 1D0000, offset^3 = 3
          4'd1: begin                                // 1D0002, offset^3 = 2
                  irq2 <= 1'b0;
                  dbg_irq2_ack <= dbg_irq2_ack + 16'd1;
                end
          4'd2: irq1 <= 1'b0;                        // 1D0004, offset^3 = 1
          4'd3: begin                                // 1D0006
                  irqs_enable  <= cpu_dout[0];
                  video_enable <= cpu_dout[3];
                  prev_bit2    <= cpu_dout[2];
                  if (~prev_bit2 &  cpu_dout[2]) raster_arm <= 1'b1;
                  if ( prev_bit2 & ~cpu_dout[2]) raster_arm <= 1'b0;
                end
          4'd4: raster_line <= cpu_dout[8:0];        // 1D0008
          4'd11: wdog_pet <= 1'b1;                    // 1D0016 watchdog
          default: ;
        endcase
      end
    end
  end

  assign dbg_irq = {irq3, irq2, irq1};

  // ---------------------------------------------------------------------
  // Video registers at 1C0000 and the two byte registers at 1D000C/D
  // ---------------------------------------------------------------------
  always @(posedge clk) begin
    sound_latch_we <= 1'b0;

    if (rst) begin
      bg0_scrollx <= 9'd0;  bg0_scrolly <= 9'd0;
      bg1_scrollx <= 9'd0;  bg1_scrolly <= 9'd0;
      flip_screen <= 1'b0;
      screen_brt  <= 8'hFF;
      sound_latch <= 8'h00;
    end else if (wr_stb) begin
      if (sel_vreg) begin
        case (a[3:1])
          3'd0: bg0_scrollx <= cpu_dout[8:0];        // 1C0000
          3'd1: bg0_scrolly <= cpu_dout[8:0];        // 1C0002
          3'd2: bg1_scrollx <= cpu_dout[8:0];        // 1C0004
          3'd3: bg1_scrolly <= cpu_dout[8:0];        // 1C0006
          3'd5: flip_screen <= cpu_dout[0];          // 1C000A
          default: ;                                 // 1C0008 / 1C000C: MAME
                                                     // nopw, purpose unknown
        endcase
      end
      // 1D000C is the sound latch (UPPER byte of the word) and 1D000D is the
      // screen brightness (LOWER byte).  Two registers, one word.
      if (sel_creg && (a[4:1] == 4'd6)) begin
        if (!uds_n) begin
          sound_latch    <= cpu_dout[15:8];
          sound_latch_we <= 1'b1;
        end
        if (!lds_n) screen_brt <= cpu_dout[7:0];
      end
    end
  end

  // ---------------------------------------------------------------------
  // Input scrambling -- docs/HARDWARE.md section 6
  //
  // MAME *assigns* rather than ORs, so the bits it never writes read as 0,
  // not as 1.  That is reproduced here: an input word is not all-ones-padded.
  // ---------------------------------------------------------------------
  wire vbl_flag = (vcnt >= VBL_FLAG_LINE[8:0]);

  reg [15:0] inp_word;
  always @(*) begin
    case (a[2:1])
      2'd0: inp_word = {2'b00, dsw2[7:6], in_system[3:0], in_p1};
      2'd1: inp_word = {2'b00, dsw2[5:0], in_p2};
      2'd2: inp_word = {2'b00, dsw1[5:0], in_extra};
      2'd3: inp_word = {2'b00, in_misc[5:3], vbl_flag, dsw1[7:6], in_other};
    endcase
  end

  // ---------------------------------------------------------------------
  // Read mux and bus acknowledge
  //
  // Every on-chip RAM here answers in one clock.  Only the ROM can stall, so
  // it is the only source that gates cpu_ack.
  // ---------------------------------------------------------------------
  reg rd_d;
  always @(posedge clk) rd_d <= cpu_rd & ce_en;

  always @(*) begin
    cpu_din = 16'hFFFF;
    if      (sel_rom)  cpu_din = rom_data;
    else if (sel_work) cpu_din = work_dout;
    else if (sel_bg)   cpu_din = bg_dout;
    else if (sel_fg)   cpu_din = fg_dout;
    else if (sel_spr)  cpu_din = spr_dout;
    else if (sel_pal)  cpu_din = pal_dout;
    else if (sel_inp)  cpu_din = inp_word;
  end

  always @(*) begin
    if (sel_rom) cpu_ack = rom_ack;
    else         cpu_ack = ce_en & (rd_d | cpu_wr);
  end

  assign dbg_addr = a;
  assign dbg_rd   = cpu_rd;
  assign dbg_wr   = cpu_wr;
  assign dbg_dout = cpu_dout;
  assign dbg_din  = cpu_din;
  assign dbg_ack  = cpu_ack;

endmodule


//----------------------------------------------------------------------------
//  Byte-writable synchronous RAM.  One clock of read latency.
//----------------------------------------------------------------------------
module sf_ram #(parameter int AW = 12) (
    input  wire            clk,
    input  wire [AW-1:0]   addr,
    input  wire [15:0]     din,
    input  wire [1:0]      we,
    output reg  [15:0]     dout
);
  reg [7:0] hi [0:(1<<AW)-1];
  reg [7:0] lo [0:(1<<AW)-1];

  always @(posedge clk) begin
    if (we[1]) hi[addr] <= din[15:8];
    if (we[0]) lo[addr] <= din[7:0];
    dout <= {hi[addr], lo[addr]};
  end
endmodule


//----------------------------------------------------------------------------
//  True dual-port RAM: port A read/write (CPU), port B read-only (video).
//  One clock of read latency on both ports.
//----------------------------------------------------------------------------
module sf_dpram #(parameter int AW = 12) (
    input  wire            clk,
    input  wire [AW-1:0]   a_addr,
    input  wire [15:0]     a_din,
    input  wire [1:0]      a_we,
    output reg  [15:0]     a_dout,
    input  wire [AW-1:0]   b_addr,
    output reg  [15:0]     b_dout
);
  reg [7:0] hi [0:(1<<AW)-1];
  reg [7:0] lo [0:(1<<AW)-1];

  always @(posedge clk) begin
    if (a_we[1]) hi[a_addr] <= a_din[15:8];
    if (a_we[0]) lo[a_addr] <= a_din[7:0];
    a_dout <= {hi[a_addr], lo[a_addr]};
    b_dout <= {hi[b_addr], lo[b_addr]};
  end
endmodule

`default_nettype wire
