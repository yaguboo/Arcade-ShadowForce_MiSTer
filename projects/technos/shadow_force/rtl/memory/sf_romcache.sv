//============================================================================
//  sf_romcache -- a small direct-mapped word cache for the 68000's program ROM
//
//  ADOPTED FROM Power Spikes.  `projects/vsystem/power_spikes/rtl/memory/
//  ps_romcache.sv`, whose header carries the measurements that justified it
//  there and is worth reading before changing anything here.  Same factory,
//  same author, no licence question -- but it is COPIED rather than shared,
//  because root CLAUDE.md 1.4 promotes to common/ only after a second
//  independent board has actually used it.  This is that second board; the
//  promotion is a candidate, recorded in docs/FACTORY_REUSE_NOTES.md, and it
//  happens in the serialised window rather than from inside a lane.
//
//  ---- why it applies here, measured on THIS board ------------------------
//
//  Shadow Force has the same shape of problem Power Spikes had:  cpu_ack is
//  rom_ack, so every 68000 instruction fetch waits for a full SDRAM
//  transaction, and the CPU is the LOWEST priority client behind three
//  graphics layers that between them ask for more than a scanline holds.
//
//  Hardware, per frame (docs/DEBUG_LOG.md A12-A15):
//
//      68000 reads                  16,339
//      68000 writes                 2
//      program addresses touched    0x0058D0 .. 0x00590F -- SIXTY-FOUR BYTES
//
//  That last line is why this is worth more here than it was there.  The CPU
//  is executing a thirty-two word loop.  A cache of 1024 entries does not
//  merely improve its hit rate, it holds the entire working set, and 16,339
//  transactions a frame collapse to a handful.
//
//  The bus those transactions were consuming is the same bus fg is short of:
//  fg completes 175 of 272 lines because the fetch path delivers about 352
//  reads per line against the 412 the three layers want (A9, A12).  Taking
//  the CPU's traffic out of that contest is the cheapest bandwidth this
//  project has available, and it costs no accuracy at all -- a cache of a
//  read-only ROM cannot change what the CPU sees.
//
//  ---- one deliberate difference from the Power Spikes version ------------
//
//  The reset is `rst | dl_active`, not `rst`.  The program ROM is WRITTEN
//  during the download, so a cache that survives it would serve bytes that
//  the loader has since replaced.  Power Spikes gets away with plain `rst`
//  because of how its reset is sequenced; relying on that here would be
//  inheriting an unstated assumption, which is exactly what that project's
//  own LESSONS_LEARNED L3 is about.
//
//  ---- and one hazard carried over ---------------------------------------
//
//  `c_rd` is a LEVEL held until acknowledged.  S_DONE waits for it to drop
//  before looking again, or a single read is acknowledged twice.  Shadow
//  Force has already been bitten by precisely this class of thing once, in
//  the SDRAM controller (DEBUG_LOG A8), where removing a one-clock guard let
//  one transaction be issued twice and hand back another client's data.
//============================================================================
module sf_romcache #(
    parameter int IDX_BITS = 10,         // 1024 entries -- see the sizing note
    parameter int AW       = 19          // word-address width, [AW:1]
) (
    input  wire            clk,
    input  wire            rst,


    // --- CPU side: same contract sf_main already speaks -------------------
    input  wire [AW:1]     c_a,
    input  wire            c_rd,         // level, held until c_ack
    output reg             c_ack,        // one-clock pulse, data valid with it
    output reg  [15:0]     c_q,

    // --- memory side: same contract the arbiter already speaks ------------
    output reg  [AW:1]     m_a,
    output reg             m_rd,
    input  wire            m_ack,
    input  wire [15:0]     m_q
);

  // No hit/miss counters here on purpose.  The overlay already carries the
  // number this cache exists to move: 68000 clocks spent waiting for ROM in a
  // frame's vblank, divided by fetches completed in it (rows 66 and 67).  That
  // was 7.19 before; a hit costs two clocks.  A separate hit counter would be
  // a second instrument for the same fact, and this project has been burned
  // more than once by trusting a counter that agreed with its own assumption
  // (LESSONS_LEARNED L12, L14).

  // SIZE IS A PARAMETER, NOT A RUNTIME INPUT, and that is not a style
  // choice.  A version of this masked the index with a runtime value so the
  // cache could be resized from the OSD.  Quartus stopped inferring M10K
  // entirely -- Total RAM Blocks 0 of 553 -- and put 4096 x 42 bits into
  // flip-flops: 178 937 ALMs against 41 910, a fitter FAILURE at 427 %.
  // LESSONS_LEARNED L24, which this project wrote after the sprite line
  // buffer did the same thing, and which says a description that cannot be
  // a memory becomes registers WITH NO WARNING.
  //
  // The index must be a plain slice of the address for the inference to
  // survive, so it is one.
  localparam int TAG_BITS = AW - IDX_BITS;

  reg                     v   [0:(1<<IDX_BITS)-1];
  reg [TAG_BITS-1:0]      tag [0:(1<<IDX_BITS)-1];
  reg [15:0]              dat [0:(1<<IDX_BITS)-1];

  wire [IDX_BITS-1:0] idx    = c_a[IDX_BITS:1];
  wire [TAG_BITS-1:0] cur_tg = c_a[AW:IDX_BITS+1];

  localparam [1:0] S_IDLE = 2'd0, S_LOOK = 2'd1, S_FILL = 2'd2, S_DONE = 2'd3;
  reg [1:0] st;

  // Registered lookup.  A combinational hit would have to drive c_ack in the
  // same clock the request appears, which puts a 128-way tag compare and the
  // data mux in one path; one clock of latency against the 7.19 being removed
  // is not worth that risk.
  reg                le_v;
  reg [TAG_BITS-1:0] le_tag;
  reg [15:0]         le_dat;
  reg [IDX_BITS-1:0] le_idx;
  reg [TAG_BITS-1:0] le_cur;

  integer i;
  always @(posedge clk) begin
    if (rst) begin
      st         <= S_IDLE;
      c_ack      <= 1'b0;
      c_q        <= 16'h0000;
      m_rd       <= 1'b0;
      m_a        <= {AW{1'b0}};
      for (i = 0; i < (1<<IDX_BITS); i = i + 1) v[i] <= 1'b0;
    end else begin
      c_ack <= 1'b0;

      case (st)
        S_IDLE: begin
          if (c_rd) begin
            le_v   <= v[idx];
            le_tag <= tag[idx];
            le_dat <= dat[idx];
            le_idx <= idx;
            le_cur <= cur_tg;
            m_a    <= c_a;
            st     <= S_LOOK;
          end
        end

        S_LOOK: begin
          if (le_v && le_tag == le_cur) begin
            c_q   <= le_dat;
            c_ack <= 1'b1;
            st    <= S_DONE;
          end else begin
            m_rd <= 1'b1;
            st   <= S_FILL;
          end
        end

        S_FILL: begin
          if (m_ack) begin
            m_rd        <= 1'b0;
            v  [le_idx] <= 1'b1;
            tag[le_idx] <= le_cur;
            dat[le_idx] <= m_q;
            c_q         <= m_q;
            c_ack       <= 1'b1;
            st          <= S_DONE;
          end
        end

        // `c_rd` is a level held until the CPU sees its acknowledge, so wait
        // for it to drop before looking at it again -- otherwise one read is
        // acknowledged twice.
        S_DONE: if (!c_rd) st <= S_IDLE;

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
