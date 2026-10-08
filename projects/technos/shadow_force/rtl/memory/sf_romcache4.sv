//============================================================================
//  sf_romcache4 -- 4-way set-associative line cache for the 68000's program ROM
//
//  Replaces sf_romcache on the CPU port only (the OKI keeps sf_romcache).
//  Same CPU-side and memory-side contracts, plus `m_hold` (D15) so a line
//  fill goes out as one four-word group instead of four separate grants.
//
//  ---- why: the 68000 ran at ~70 % in the Tengu demo (DEBUG_LOG O-TENGU) ----
//
//  Board row 5 read 34-36 k CPU reads a frame there against MAME's ~50 k
//  (the same instrument read 56,863 = 56,863 at boot).  MAME's own ROM
//  address stream for that scene (tools: session lua, 300 frames, 11.5 M
//  reads) touches ~4,700 distinct words a frame, and the 1,024-word
//  direct-mapped cache that stood here missed **~7,100 times a frame**, each
//  miss waiting behind four video clients at the lowest priority.  Replaying
//  the same streams through candidate caches (misses/frame, median / max):
//
//      1K words direct-mapped (old)             tengu 7,084 / 8,663
//      16K words, 4-way, 4-word lines, global RR tengu 33 / 236
//                                                blue 33 / 381  coyote 38 / 285
//
//  Global round-robin replacement measured within noise of true LRU, so
//  there is no per-set replacement state at all.
//
//  ---- geometry ---------------------------------------------------------
//
//      word address [AW:1] = { tag[TAG_BITS], set[SET_BITS], off[2] }
//      AW 19, SET_BITS 10  ->  TAG_BITS 7
//      data  4 ways x 4096 x 16   (one inferred RAM per way)
//      tags  4 ways x 1024 x 8    ({valid, tag})
//
//  Index slices are plain address bits, because a description that cannot be
//  a memory becomes flip-flops without a warning (LESSONS_LEARNED L24 and
//  the 427 % fitter failure recorded in sf_romcache.sv).
//
//  ---- a hit is two clocks, as before -----------------------------------
//
//  The RAMs are read every clock at the set/offset of `c_a`; `c_a` is held
//  until the ack, so the registered words in S_LOOK belong to this request.
//
//  ---- a miss fills the whole line, critical word first ------------------
//
//  Word order is (off + n) & 3, all inside one 4-word-aligned group -- one
//  SDRAM row.  The CPU is acknowledged on the FIRST word (its own) and the
//  other three keep filling.  Because the CPU may drop `c_rd` and raise the
//  next request while that happens, `dropped` records whether the level
//  went low after the ack; the end of the fill goes straight back to S_IDLE
//  if it did, instead of waiting for a drop that has already happened.
//
//  ---- valid bits are cleared by a sweep, not a reset loop ---------------
//
//  1,024 clocks after reset (the download reset included -- the ROM is being
//  rewritten under it), writing {valid 0} to every set of every way.
//============================================================================
`default_nettype none

module sf_romcache4 #(
    parameter int AW       = 19,         // word-address width, [AW:1]
    parameter int SET_BITS = 10
) (
    input  wire            clk,
    input  wire            rst,

    input  wire [AW:1]     c_a,
    input  wire            c_rd,         // level, held until c_ack
    output reg             c_ack,        // one-clock pulse, data valid with it
    output reg  [15:0]     c_q,

    output reg  [AW:1]     m_a,
    output reg             m_rd,
    output wire            m_hold,       // D15: another word of this line follows
    input  wire            m_ack,
    input  wire [15:0]     m_q
);

  localparam int TAG_BITS = AW - SET_BITS - 2;
  localparam int NSET     = 1 << SET_BITS;

  wire [1:0]          off_c = c_a[2:1];
  wire [SET_BITS-1:0] set_c = c_a[SET_BITS+2:3];
  wire [TAG_BITS-1:0] tag_c = c_a[AW:SET_BITS+3];

  // ---- valid sweep ------------------------------------------------------
  reg [SET_BITS-1:0] clr_ptr;
  reg                clr_busy;
  always @(posedge clk) begin
    if (rst) begin
      clr_ptr  <= {SET_BITS{1'b0}};
      clr_busy <= 1'b1;
    end else if (clr_busy) begin
      clr_ptr <= clr_ptr + 1'b1;
      if (&clr_ptr) clr_busy <= 1'b0;
    end
  end

  // ---- FSM state used by the RAM write ports ----------------------------
  localparam [2:0] S_IDLE = 3'd0, S_LOOK = 3'd1, S_FILL = 3'd2, S_DONE = 3'd3;
  reg [2:0]          st;
  reg [1:0]          victim, rr;
  reg [1:0]          n, off_l;
  reg [SET_BITS-1:0] set_l;
  reg [TAG_BITS-1:0] tag_l;
  reg                dropped;

  wire               fill_we  = (st == S_FILL) && m_ack;
  wire               fill_end = fill_we && (n == 2'd3);
  wire [1:0]         fill_off = off_l + n;

  assign m_hold = (st == S_FILL) && (n != 2'd3);

  // ---- the four ways ----------------------------------------------------
  wire [TAG_BITS:0] tq [0:3];
  wire [15:0]       dq [0:3];

  genvar w;
  generate
    for (w = 0; w < 4; w = w + 1) begin : g_way
      reg [TAG_BITS:0] tag_ram [0:NSET-1];
      reg [15:0]       dat_ram [0:4*NSET-1];
      reg [TAG_BITS:0] tq_r;
      reg [15:0]       dq_r;

      wire t_we = clr_busy | (fill_end && victim == w);
      wire [SET_BITS-1:0] t_wa = clr_busy ? clr_ptr : set_l;
      wire [TAG_BITS:0]   t_wd = clr_busy ? {(TAG_BITS+1){1'b0}} : {1'b1, tag_l};

      always @(posedge clk) begin
        if (t_we) tag_ram[t_wa] <= t_wd;
        tq_r <= tag_ram[set_c];
      end
      always @(posedge clk) begin
        if (fill_we && victim == w) dat_ram[{set_l, fill_off}] <= m_q;
        dq_r <= dat_ram[{set_c, off_c}];
      end
      assign tq[w] = tq_r;
      assign dq[w] = dq_r;
    end
  endgenerate

  wire [3:0] hit;
  assign hit[0] = tq[0][TAG_BITS] && (tq[0][TAG_BITS-1:0] == tag_l);
  assign hit[1] = tq[1][TAG_BITS] && (tq[1][TAG_BITS-1:0] == tag_l);
  assign hit[2] = tq[2][TAG_BITS] && (tq[2][TAG_BITS-1:0] == tag_l);
  assign hit[3] = tq[3][TAG_BITS] && (tq[3][TAG_BITS-1:0] == tag_l);
  wire [15:0] hit_q = hit[0] ? dq[0] : hit[1] ? dq[1] : hit[2] ? dq[2] : dq[3];

  always @(posedge clk) begin
    if (rst) begin
      st     <= S_IDLE;
      c_ack  <= 1'b0;
      c_q    <= 16'h0000;
      m_rd   <= 1'b0;
      m_a    <= {AW{1'b0}};
      rr     <= 2'd0;
      n      <= 2'd0;
      dropped <= 1'b0;
    end else begin
      c_ack <= 1'b0;
      if (!c_rd) dropped <= 1'b1;

      case (st)
        S_IDLE: if (c_rd && !clr_busy) begin
          // The RAMs are reading set_c/off_c this clock; S_LOOK sees them.
          set_l <= set_c;
          tag_l <= tag_c;
          off_l <= off_c;
          st    <= S_LOOK;
        end

        S_LOOK: begin
          if (|hit) begin
            c_q   <= hit_q;
            c_ack <= 1'b1;
            st    <= S_DONE;
          end else begin
            victim <= rr;
            rr     <= rr + 2'd1;
            n      <= 2'd0;
            m_a    <= {tag_l, set_l, off_l};
            m_rd   <= 1'b1;
            st     <= S_FILL;
          end
        end

        S_FILL: if (m_ack) begin
          if (n == 2'd0) begin
            c_q     <= m_q;
            c_ack   <= 1'b1;
            dropped <= 1'b0;
          end
          if (n == 2'd3) begin
            m_rd <= 1'b0;
            // `dropped` is cleared on the first word's ack and set by any
            // later clock with c_rd low; this clock's own c_rd counts too.
            st   <= (dropped || !c_rd) ? S_IDLE : S_DONE;
          end else begin
            m_a <= {tag_l, set_l, off_l + n + 2'd1};
          end
          n <= n + 2'd1;
        end

        // `c_rd` is held until the CPU sees its acknowledge: wait for it to
        // drop, or one read is acknowledged twice.
        S_DONE: if (!c_rd) st <= S_IDLE;

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
