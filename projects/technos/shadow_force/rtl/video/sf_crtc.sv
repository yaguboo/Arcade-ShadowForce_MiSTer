//============================================================================
//  Shadow Force -- video timing
//
//  docs/HARDWARE.md section 2 has the derivation.  In short:
//
//      pixel clock  7.000 MHz    = 28 MHz crystal / 4
//      H total      448          visible x = 0..319
//      V total      272          visible y = 8..247   (240 lines)
//      line rate    15625.0 Hz   vs 15624.8 Hz measured on a PCB
//      refresh      57.4449 Hz   vs 57.4446 Hz measured on a PCB
//
//  MAME calls the two totals "guessed".  They are INFERRED here rather than
//  HW_CONFIRMED, but they reproduce two independent frequency-counter
//  readings recorded in the same driver header to five digits, and there is
//  no competing candidate.
//
//  **vcnt counts raw screen lines 0..271, and the visible window starts at
//  line 8.**  That is deliberate and load-bearing: MAME's scanline timer,
//  its vblank flag and its raster compare all use this same numbering, so
//  keeping it means the interrupt arithmetic in sf_main is literally the
//  same numbers as the driver's.  Renumbering so that line 0 is the first
//  visible line would silently shift every interrupt by 8 lines.
//
//  Sync positions are UNVERIFIED -- nothing documents them.  They sit inside
//  the blanking interval with roughly NTSC proportions so a scaler locks,
//  and they affect where the image sits in the scaler's window and nothing
//  else about the board.
//============================================================================
`default_nettype none

module sf_crtc #(
    parameter int H_TOTAL     = 448,
    parameter int H_VISIBLE   = 320,
    parameter int H_SYNC_ON   = 344,   // UNVERIFIED
    parameter int H_SYNC_W    = 36,    // UNVERIFIED  (~5.1 us)
    parameter int V_TOTAL     = 272,
    parameter int V_VIS_START = 8,     // first visible line, MAME_VERIFIED
    parameter int V_VIS_END   = 248,   // first blanked line, MAME_VERIFIED
    parameter int V_SYNC_ON   = 254,   // UNVERIFIED
    parameter int V_SYNC_W    = 4      // UNVERIFIED
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,

    output reg  [8:0]  hcnt,
    output reg  [8:0]  vcnt,          // raw screen line, 0..V_TOTAL-1
    output reg         hblank,
    output reg         vblank,
    output reg         hsync,
    output reg         vsync,
    output wire        visible,

    // one ce_pix-wide pulse at the first pixel of line V_VIS_END
    output reg         vblank_start,
    // one ce_pix-wide pulse at the start of every line
    output reg         line_start
);

  assign visible = ~hblank & ~vblank;

  always @(posedge clk) begin
    vblank_start <= 1'b0;
    line_start   <= 1'b0;

    if (rst) begin
      hcnt   <= 9'd0;
      vcnt   <= 9'd0;
      hblank <= 1'b0;
      vblank <= 1'b1;
      hsync  <= 1'b0;
      vsync  <= 1'b0;
    end else if (ce_pix) begin
      if (hcnt == H_TOTAL - 1) begin
        hcnt       <= 9'd0;
        line_start <= 1'b1;
        if (vcnt == V_TOTAL - 1) vcnt <= 9'd0;
        else                     vcnt <= vcnt + 9'd1;
      end else begin
        hcnt <= hcnt + 9'd1;
      end

      // Blanking and sync are decoded from the *next* counter value so the
      // flags line up with the pixel they belong to.
      begin : decode
        reg [8:0] nh, nv;
        nh = (hcnt == H_TOTAL - 1) ? 9'd0 : hcnt + 9'd1;
        nv = (hcnt == H_TOTAL - 1)
             ? ((vcnt == V_TOTAL - 1) ? 9'd0 : vcnt + 9'd1)
             : vcnt;

        hblank <= (nh >= H_VISIBLE);
        vblank <= (nv < V_VIS_START) || (nv >= V_VIS_END);
        hsync  <= (nh >= H_SYNC_ON) && (nh < H_SYNC_ON + H_SYNC_W);
        vsync  <= (nv >= V_SYNC_ON) && (nv < V_SYNC_ON + V_SYNC_W);

        if (nv == V_VIS_END && nh == 0) vblank_start <= 1'b1;
      end
    end
  end

endmodule

`default_nettype wire
