//============================================================================
//  Shadow Force -- ioctl byte stream -> SDRAM words
//
//  This is platform transport, so it lives in integration/ and not in rtl/:
//  root CLAUDE.md section 4 keeps ioctl_* out of the board.  The board sees
//  only dl_addr / dl_data / dl_req / dl_ack.
//
//  The MRA tool streams the download image one byte at a time, ascending
//  from 0.  SDRAM is 16 bits wide, and sf_rommap.svh fixes the convention:
//
//      word W  =  { byte 2W , byte 2W+1 }      byte 2W in bits [15:8]
//
//  which is big-endian, so the 68000 reads program words the right way round
//  with no further swapping anywhere in the core.  tools/build_rom.py has
//  already interleaved the 68000 region's four ROM_LOAD16_BYTE halves, so the
//  two conventions meet exactly here.  Check the reset vector if this is ever
//  in doubt: SSP must read 0x001FFA00 and PC 0x000055C6, which the builder
//  asserts and overlay rows 12-15 read back off hardware.
//
//  ioctl_wait is asserted while a word is waiting to go into SDRAM.  Without
//  it the HPS outruns the memory bus and the tail of the image is lost --
//  silently, because a ROM that is 99 % correct still boots for a while.
//============================================================================
`default_nettype none

module sf_download (
    input  wire        clk,
    input  wire        rst,

    // --- from the platform --------------------------------------------------
    input  wire        ioctl_download,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire [7:0]  ioctl_dout,
    input  wire [15:0] ioctl_index,
    output wire        ioctl_wait,

    // --- to the board's memory port ----------------------------------------
    output reg  [24:0] dl_addr,
    output reg  [15:0] dl_data,
    output reg         dl_req = 1'b0,   // see the note on `busy` below
    input  wire        dl_ack,
    output wire        dl_active
);

  // The MRA's <rom index="0"> is the ROM image.  Match all 16 bits: index
  // 0x00FE is the later <switches> transfer and must not reach ROM space.
  wire is_rom = (ioctl_index == 16'd0);

  reg [7:0] hold;      // the even byte, waiting for its odd partner

  // ---- D20: the sprite ROM is re-laid-out ON THE WAY IN --------------------
  //
  // A .mra is an assembly INSTRUCTION SHEET -- <part name="32j4-0.12"/> and
  // friends, concatenated by MiSTer out of the zip -- so it can express
  // MAME's even/odd interleave and nothing else.  A permutation put in
  // build_rom.py's assembled image therefore never reaches the board, which
  // is exactly what happened for two builds (DEBUG_LOG A35).
  //
  // It has to happen where the bytes are still bytes, which is here.
  //
  // The board stores a 16x16 sprite tile, one bitplane, as 32 bytes:
  //     [ left half, rows 0..15 ][ right half, rows 0..15 ]
  // with the five planes in five 2 MB ROMs.  So one 16-bit read returns the
  // same half of two adjacent rows, and the five reads that make one row of
  // pixels are a megabyte apart: ten accesses a row, all of them row changes,
  // half of every word discarded.
  //
  // Written instead as   word(tile, ty, plane) = tile*80 + ty*5 + plane
  // a row is FIVE CONSECUTIVE WORDS: one activate and four hits, nothing
  // discarded.  Same 5 242 880 words, so REGIONS and the download length do
  // not move.  Root CLAUDE.md 6, BUILD_TIME_ONLY: ROM packing -- one stage
  // later than the build, for the reason above.
  //
  // The two halves of one row are SIXTEEN bytes apart in the incoming stream,
  // so sixteen of them have to be held rather than one.
  `include "sf_rommap.svh"
  localparam [26:0] SPR_LO = {SPRITES_BASE_W, 1'b0};          // byte address
  localparam [26:0] SPR_HI = {OKI_BASE_W,     1'b0};
  wire        in_spr  = is_rom && (ioctl_addr >= SPR_LO) && (ioctl_addr < SPR_HI);
  wire [26:0] spr_off = ioctl_addr - SPR_LO;
  wire [2:0]  spr_k   = spr_off[23:21];        // plane, 2 MB apart in the zip
  wire [15:0] spr_t   = spr_off[20:5];         // tile, 32 bytes each
  wire        spr_h   = spr_off[4];            // 0 = left half, 1 = right
  wire [3:0]  spr_y   = spr_off[3:0];          // row within the tile
  // 25 bits BEFORE the shift: a shift keeps the width of its left operand and
  // tile*64 needs twenty-two (the trap D20 recorded).
  wire [24:0] spr_w   = SPRITES_BASE_W
                      + ({9'd0, spr_t} << 6) + ({9'd0, spr_t} << 4)
                      + ({21'd0, spr_y} << 2) + {21'd0, spr_y}
                      + {22'd0, spr_k};
  reg  [7:0]  sbuf [0:15];     // the left halves of the block being received

  // THE POWER-UP VALUE HERE IS NOT OPTIONAL.
  //
  // ioctl_wait goes onto HPS_BUS[37], which sys_top.v calls io_wait, and
  // io_wait high stops sys_top from ever raising io_ack.  MiSTer's main
  // spins on io_ack for EVERY word it sends the core, so a `busy` that comes
  // out of configuration set wedges the HPS before the core has done
  // anything at all.  The .qsf sets ALLOW_POWER_UP_DONT_CARE, which makes an
  // uninitialised register genuinely free to power up either way.
  //
  // Inherited verbatim from NA-1/NA-2's na2_membus, which carries the same
  // comment on the same signal for the same reason.  Nothing else in this
  // core has that reach.
  reg       busy = 1'b0;

  assign ioctl_wait = busy;
  // Keep write ownership through the acknowledgement of the final word.  The
  // host may lower ioctl_download immediately after presenting its last byte.
  assign dl_active = (ioctl_download & is_rom) | busy;

  always @(posedge clk) begin
    if (rst) begin
      dl_req <= 1'b0;
      busy   <= 1'b0;
      hold   <= 8'd0;
    end else begin
      if (dl_req && dl_ack) begin
        dl_req <= 1'b0;
        busy   <= 1'b0;
      end

      if (ioctl_wr && is_rom) begin
        if (in_spr) begin
          // Left halves are held until their right partner arrives sixteen
          // bytes later; the pair is then one word of the new layout.  Half 0
          // is the LEFT eight pixels and the blit reads it as pl[{1'b0, k}],
          // so in a big-endian image it is the HIGH byte.  Reversed, every
          // sprite has its left and right eight columns exchanged.
          if (!spr_h) begin
            sbuf[spr_y] <= ioctl_dout;
          end else begin
            dl_addr <= spr_w;
            dl_data <= {sbuf[spr_y], ioctl_dout};
            dl_req  <= 1'b1;
            busy    <= 1'b1;
          end
        end else if (!ioctl_addr[0]) begin
          // even byte: high half of the word, held until the odd byte
          hold <= ioctl_dout;
        end else begin
          dl_addr <= ioctl_addr[25:1];
          dl_data <= {hold, ioctl_dout};
          dl_req  <= 1'b1;
          busy    <= 1'b1;
        end
      end
    end
  end

endmodule

`default_nettype wire
