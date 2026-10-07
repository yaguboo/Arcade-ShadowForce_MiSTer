//============================================================================
//  Shadow Force -- SDRAM controller for the MiSTer SDRAM module
//
//  Single port, one 16-bit word per transaction, auto-precharge, CAS latency 2.
//  Deliberately simple: the whole core needs about 3.5 M accesses per second
//  (the 68000 manages one bus cycle per 16 system clocks at most, and the C70
//  stand-in and blitter add a little on top), while this controller delivers
//  roughly one access every 8 clocks at 50.113 MHz -- around 6 M/s.  Page-mode
//  bursts would help the blitter and can be added later behind the same
//  interface; see KNOWN_ISSUES.md.
//
//  Interface matches the `mem_*` port of ps_top exactly, so a behavioural
//  model and this controller are drop-in equivalents:
//      req    held high until ack
//      ack    one clock, read data valid in the same clock
//
//  A write with ds != 2'b11 costs two transactions rather than one: the board
//  does not honour DQM, so byte writes are done read-modify-write.  See the
//  block comment on rmw_rd below and KNOWN_ISSUES.md RISK-8.
//
//  ---- timing is DERIVED here, not assumed ------------------------------
//
//  Power Spikes inherited this controller with tRCD and tRP hard-coded to one
//  clock each.  Its docs/FACTORY_REUSE.md section 2 records the consequence:
//  the constants "assume one clock is enough for tRCD and tRP, which holds
//  only below about 55 MHz.  That is not written down anywhere in the module.
//  It is why this board runs at 40 MHz and not the 80 MHz first considered",
//  and it recommends deriving them from CLK_HZ on any reuse.
//
//  Shadow Force runs at 56 MHz (DECISIONS D1), which is on the wrong side of
//  that line, so the constants below are computed from CLK_HZ and the
//  nanosecond figures for the -6A/-7 parts on the MiSTer SDRAM boards:
//
//      tRCD >= 18 ns     tRP >= 18 ns     tRC >= 60 ns     CL = 2
//      tREF  = 64 ms / 8192 rows -> one AUTO REFRESH every 7.8 us
//
//  At 56 MHz (tCK = 17.857 ns) that gives tRCD = tRP = 2 clocks and tRC = 4,
//  where the original would have used 1 and been short on every row
//  activation.  At 40 MHz the same arithmetic reproduces the original numbers,
//  so Power Spikes' measured behaviour is not disturbed by the change.
//
//  Address mapping: the caller supplies a flat word address.  Rows and columns
//  are taken as {row[12:0], bank[1:0], col[9:0]} so that sequential words stay
//  inside one row for as long as possible, which is what the blitter and the
//  68000's prefetch both do.
//============================================================================
`default_nettype none

module sf_sdram #(
    parameter int CLK_HZ  = 56_000_000,
    parameter int INIT_US = 200,            // power-up wait
    // Device timing in picoseconds, so every intermediate stays an integer.
    parameter int TRCD_PS = 18_000,
    parameter int TRP_PS  = 18_000,
    parameter int TRC_PS  = 60_000,
    parameter int TREF_NS = 7_800           // per row, 64 ms / 8192
) (
    input  wire        clk,          // SDRAM clock (same domain as the core)
    input  wire        init,         // hold high to (re)run the init sequence
    // One pulse a frame.  The three row counters below used to freeze together
    // on saturation, which made their RATIO honest and their AGE useless: they
    // described the first ~65k accesses, about 2 ms after reset, and every
    // screenshot of a run read the identical values.  That is the ROM-download
    // era, and it reported 71.9 % row hits -- which is how a clocks-per-read
    // of 6.20 was computed for a bus that measures 9.21.
    input  wire        frame,

    // --- request port -------------------------------------------------------
    input  wire [24:0] addr,         // word address
    input  wire [15:0] din,
    output reg  [15:0] dout,
    input  wire        req,
    input  wire        we,
    input  wire [1:0]  ds,           // {upper byte, lower byte}
    output reg         ack,
    // D22b.  The OFFER: this read acks next clock.  Not a permission.
    output wire        ack_early,
    // The ACCEPTANCE, from the arbiter, registered there.  The fast path
    // below gates on THIS and never on `req` -- `ack` is assigned
    // non-blocking, so during S_CL3 m_ack is still 0 and `req` is high
    // whether or not the hand-over happened.  Gating on `req` is what killed
    // three bitstreams (DEBUG_LOG A41).
    input  wire        handoff,

    // --- SDRAM pins ---------------------------------------------------------
    output reg  [12:0] SDRAM_A,
    output reg  [1:0]  SDRAM_BA,
    inout  wire [15:0] SDRAM_DQ,
    output reg         SDRAM_DQML,
    output reg         SDRAM_DQMH,
    output wire        SDRAM_nCS,
    output reg         SDRAM_nWE,
    output reg         SDRAM_nRAS,
    output reg         SDRAM_nCAS,
    output reg         SDRAM_CKE,

    // --- D7a observability --------------------------------------------------
    //
    // The change either raises the hit rate or it does not, and only the board
    // can say which.  DEBUG_LOG A7 is the measurement that made D7a necessary;
    // these are the measurement that says whether it worked.
    output reg  [15:0] dbg_row_hit,
    output reg  [15:0] dbg_row_miss,
    output reg  [15:0] dbg_row_conflict,

    // --- where the line actually goes ---------------------------------------
    //
    // 10.2 clocks per read was computed BACKWARDS from how many tiles fg
    // finished.  It does not say how much of that is the controller doing
    // work and how much is the bus sitting idle with a request waiting --
    // and those pick different fixes.  A burst interface attacks the first;
    // arbiter turnaround attacks the second.  So count both.
    output reg  [15:0] dbg_bus_work,   // clocks servicing a transaction
    output reg  [15:0] dbg_bus_waste   // clocks idle WITH a request pending
);

  localparam int INIT_CLKS = (CLK_HZ / 1_000_000) * INIT_US;   // ~11200

  // ---- derived timing ----------------------------------------------------
  localparam int PS_PER_CLK = 1_000_000_000 / (CLK_HZ / 1000);
  localparam int TRCD_CLKS  = (TRCD_PS + PS_PER_CLK - 1) / PS_PER_CLK;
  localparam int TRP_CLKS   = (TRP_PS  + PS_PER_CLK - 1) / PS_PER_CLK;
  localparam int TRC_CLKS   = (TRC_PS  + PS_PER_CLK - 1) / PS_PER_CLK;

  // Clocks between AUTO REFRESH, keeping the same ~10 % margin the original
  // kept when it used 350 where 391 was allowed.
  localparam int REFRESH_CLK = (TREF_NS * (CLK_HZ / 1_000_000)) / 1000 * 9 / 10;

  // A read occupies ACTIVE + tRCD + CMD + 3 states (see the S_CL3 comment),
  // so the extra idle the sequencer must still add to honour tRC is whatever
  // tRC has left over.  Never let it reach zero: S_IDLE needs one state to
  // notice the timer at all.
  localparam int RD_LEN       = 2 + TRCD_CLKS + 3;
  localparam int WR_LEN       = 2 + TRCD_CLKS;
  localparam int TRC_AFTER_RD = (TRC_CLKS > RD_LEN) ? (TRC_CLKS - RD_LEN) : 1;
  localparam int TRC_AFTER_WR = (TRC_CLKS > WR_LEN) ? (TRC_CLKS - WR_LEN) : 1;

  // command encoding {nRAS, nCAS, nWE}
  localparam [2:0] CMD_NOP        = 3'b111,
                   CMD_ACTIVE     = 3'b011,
                   CMD_READ       = 3'b101,
                   CMD_WRITE      = 3'b100,
                   CMD_PRECHARGE  = 3'b010,
                   CMD_REFRESH    = 3'b001,
                   CMD_LOADMODE   = 3'b000;

  // Mode register: burst length 1, sequential, CAS latency 2, single write
  localparam [12:0] MODE = 13'b000_0_00_010_0_000;

  assign SDRAM_nCS = 1'b0;          // always selected

  // ---- bidirectional data bus -------------------------------------------
  reg        dq_oe;
  reg [15:0] dq_out;
  assign SDRAM_DQ = dq_oe ? dq_out : 16'hZZZZ;

  // ---- address decomposition --------------------------------------------
  //
  // The bank is HASHED, and D13 is why.  D7a leaves one row open per bank so
  // that the words of a tile row, sixteen apart, all hit it.  The address map
  // made that impossible:
  //
  //     bg tile word     = TILES   + f*0x80000  + tile*32 + py + h*16
  //     sprite row word  = SPRITES + k*0x100000 + tile*16 + half*8 + ty[3:1]
  //
  // f*0x80000 is bit 19 and k*0x100000 is bit 20, so neither the tile third
  // nor the sprite plane reaches addr[11:10].  One bg tile's six words came
  // out as three rows of ONE bank; one sprite tile row's ten words as five
  // rows of one bank, each half re-opening the row the other had just closed.
  // Measured on hardware: 9.21 clocks per read, 389 of the 627 words a line
  // needs.  Replaying one line's 842 real addresses through a model of
  // row_valid/row_open gives 40.1 % conflicts, against the 40 % back-derived
  // from that 9.21 -- two independent routes to the same number
  // (docs/DEBUG_LOG.md A27).
  //
  // **The hash cannot alias, and that is what makes it cheap.**  Row is
  // addr[24:12] and column addr[9:0], so two addresses sharing both differ
  // only in addr[11:10]; every XOR partner is a row bit, equal by assumption,
  // so their banks differ too.  (row, bank, col) still names the word
  // uniquely -- no capacity is lost and no aliasing is introduced.
  //
  // The partners are chosen to separate exactly what the map failed to:
  // addr[20:19] splits a tile's three thirds across three banks, addr[22:21]
  // splits the sprite planes.  A search over every one-, two- and three-term
  // XOR of row-bit pairs tops out at the same 86.5 % hit rate, and the residue
  // is structural -- five sprite planes do not fit four banks.
  //
  //     current   hit 59.4 %  conflict 40.1 %  ->  457 reads a line
  //     hashed    hit 86.5 %  conflict 13.1 %  ->  603 reads a line
  //
  // 603 covers an odd line's 547 and not an even line's 627, so this is half
  // of D13; the arbiter's ack bubble is the other half and goes in its own
  // build so the counters can be read between them.
  wire [9:0]  a_col  = addr[9:0];
  wire [1:0]  a_bank = addr[11:10] ^ addr[20:19] ^ addr[22:21];
  wire [12:0] a_row  = addr[24:12];

  // ---- sequencer ---------------------------------------------------------
  localparam S_INIT       = 4'd0,
             S_INIT_PRE   = 4'd1,
             S_INIT_REF1  = 4'd2,
             S_INIT_REF2  = 4'd3,
             S_INIT_MODE  = 4'd4,
             S_IDLE       = 4'd5,
             S_ACTIVE     = 4'd6,
             S_RCD        = 4'd7,
             S_CMD        = 4'd8,
             S_CL1        = 4'd9,
             S_CL2        = 4'd10,
             S_CL3        = 4'd11,
             S_REFRESH    = 4'd12,
             S_REF_WAIT   = 4'd13,
             S_PRE        = 4'd14,    // precharge one bank, then re-ACTIVE
             S_PRE_ALL    = 4'd15;    // precharge every bank, then REFRESH

  reg [3:0]  st;
  reg [15:0] timer;
  assign ack_early = (st == S_CL2) && !rmw_rd;

  // The fast path fires only on an ACCEPTED hand-over.  The declined case is
  // counted in sf_memarb, which already has a debug route to the overlay --
  // adding a second 16-bit path from here cost -0.388 ns on the HDMI clock,
  // twice, identically, which is structural and not fitter noise.
  wire chain_ok = (st == S_CL3) && !rmw_rd && req && !we && !ref_due
                  && row_hit && handoff;

  reg [15:0] ref_cnt;
  reg        ref_due;
  reg        rd_pending;

  // ---- D7a: one open row per bank ---------------------------------------
  //
  // Every READ used to carry A10=1 (auto precharge), so a word cost
  // ACTIVE + tRCD + CAS + CL -- about 8 clocks -- however close together the
  // words were.  A scanline is 3584 clocks at 56 MHz and the three tile layers
  // need 412 reads, which is 3708.  Hardware measured exactly what that
  // predicts: fg completed 0 lines of 43,780 (docs/DEBUG_LOG.md A7).
  //
  // Rows are now left open, tracked PER BANK.  Per bank matters: the arbiter
  // interleaves six clients at unrelated addresses, and a single open row
  // would thrash on every switch.  The part has four banks, and a_bank is
  // addr[11:10], so 1024 words map to one row and the words of a tile row --
  // 16 apart -- sit inside one.
  //
  // A hit skips ACTIVE and tRCD: S_IDLE -> S_CMD -> CL -> done.
  // A conflict (bank open on a DIFFERENT row) costs an explicit PRECHARGE,
  // which auto precharge never needed.  So this is a win only while hits
  // dominate, and dbg_row_* exists so that is checked rather than assumed.
  reg [3:0]  row_valid;
  reg [12:0] row_open [0:3];

  // The three counters are a RATIO, so they have to stop together.  Left to
  // wrap independently at 16 bits they compare residues, not counts, and the
  // hit rate computed from them is arithmetic on noise.  When any one is
  // about to saturate, all three freeze: the ratio then describes the first
  // ~65k events, which is what the question needs.
  // Accumulate and publish per frame, like every other counter on this board
  // that turned out to be lying.  The ratio is still taken from one frame's
  // worth of accesses, so it is still a ratio of real counts and not of
  // residues -- it is simply THIS frame's instead of the download's.
  reg [15:0] hit_a, miss_a, conf_a;
  wire ctr_full = (hit_a == 16'hFFFF) | (miss_a == 16'hFFFF) | (conf_a == 16'hFFFF);
  // Published on the frame pulse, inside the main sequencer's own always block
  // -- two blocks driving one reg is a multiple-driver error, and splitting
  // them would also let the publish and the accumulate disagree about which
  // frame they belong to.

  // Same rule for the bus pair: a ratio whose halves wrap independently is
  // arithmetic on residues, so they stop together.
  wire bus_full = (dbg_bus_work == 16'hFFFF) | (dbg_bus_waste == 16'hFFFF);

  wire       bank_is_open = row_valid[a_bank];
  wire       row_hit      = bank_is_open && (row_open[a_bank] == a_row);
  wire       row_conflict = bank_is_open && (row_open[a_bank] != a_row);

  // ---- read-modify-write for byte writes --------------------------------
  // On the DE10-Nano this core runs on, DQM is not honoured on writes.
  //
  // INHERITED EVIDENCE, not measured by this project: the NA-1/NA-2 project
  // established it on the same physical machine.  Its na2_membus self-test
  // wrote 0x0000 as a word, then 0x00A5 with ds=01, then 0x5A00 with ds=10,
  // and read back 0x5A00 -- 256 byte writes, 256 mismatches, while the same
  // 256 word writes read back clean.  Every write puts both bytes down.
  //             HW_CONFIRMED for that board; assumed to hold for this one
  //             because it is the same board.  Re-measure before trusting it
  //             on any other MiSTer.
  //
  // Power Spikes needs this for the same reason NA-2 did: the 68000 writes
  // bytes into work RAM, and work RAM is not in SDRAM here -- but the sprite
  // lookup RAM and palette are byte-writable too, and any region that ever
  // moves to SDRAM inherits the problem.  Keeping RMW costs one extra
  // transaction on byte writes only.
  //
  // So a write whose ds is not 2'b11 becomes read-modify-write: read the word,
  // merge the enabled lanes, write the whole word back with both DQM low.
  // That is correct whether or not DQM is wired, and it costs one extra
  // transaction on byte writes only.  Per-lane DQM is still driven, so if the
  // board turns out to be fine nothing about the full-word path changes.
  reg        rmw_rd;      // the read in flight is the R half of a byte write
  reg        rmw_wr;      // the next access is the W half of a byte write
  reg [15:0] rmw_data;    // merged word waiting to go back

  wire       byte_wr = we & (ds != 2'b11);

  task automatic cmd(input [2:0] c);
    begin
      SDRAM_nRAS <= c[2];
      SDRAM_nCAS <= c[1];
      SDRAM_nWE  <= c[0];
    end
  endtask

  always @(posedge clk) begin
    // defaults every clock
    cmd(CMD_NOP);
    ack   <= 1'b0;
    dq_oe <= 1'b0;

    // refresh timer runs regardless of state
    if (ref_cnt == REFRESH_CLK[15:0]) begin
      ref_cnt <= 16'd0;
      ref_due <= 1'b1;
    end else
      ref_cnt <= ref_cnt + 16'd1;

    if (init) begin
      st         <= S_INIT;
      timer      <= INIT_CLKS[15:0];
      ref_cnt    <= 16'd0;
      ref_due    <= 1'b0;
      rd_pending <= 1'b0;
      rmw_rd     <= 1'b0;
      rmw_wr     <= 1'b0;
      SDRAM_CKE  <= 1'b1;
      SDRAM_DQML <= 1'b1;
      SDRAM_DQMH <= 1'b1;
      SDRAM_A    <= 13'd0;
      SDRAM_BA   <= 2'd0;
      row_valid  <= 4'd0;
      dbg_row_hit      <= 16'd0;
      dbg_row_miss     <= 16'd0;
      dbg_row_conflict <= 16'd0;
      hit_a <= 16'd0; miss_a <= 16'd0; conf_a <= 16'd0;
      dbg_bus_work  <= 16'd0;
      dbg_bus_waste <= 16'd0;
    end else begin
      // The row-hit ratio for THIS frame, published and restarted together so
      // the three are always counts from one frame rather than residues.
      if (frame) begin
        dbg_row_hit      <= hit_a;
        dbg_row_miss     <= miss_a;
        dbg_row_conflict <= conf_a;
        hit_a <= 16'd0; miss_a <= 16'd0; conf_a <= 16'd0;
      end

      // Charged every clock, before the case: "work" is any state that is
      // part of servicing a transaction, "waste" is S_IDLE with a request
      // already waiting -- the turnaround the arbiter and the ack guard cost.
      // Init and refresh states are neither and are not counted.
      if (!bus_full) begin
        if (st == S_ACTIVE || st == S_RCD || st == S_CMD || st == S_CL1
            || st == S_CL2 || st == S_CL3 || st == S_PRE)
          dbg_bus_work <= dbg_bus_work + 16'd1;
        else if (st == S_IDLE && req)
          dbg_bus_waste <= dbg_bus_waste + 16'd1;
      end
      case (st)
        // ---------------- power-up sequence ----------------------------
        S_INIT: begin
          if (timer == 0) st <= S_INIT_PRE;
          else            timer <= timer - 16'd1;
        end
        S_INIT_PRE: begin
          cmd(CMD_PRECHARGE);
          SDRAM_A[10] <= 1'b1;              // all banks
          timer       <= 16'd4;
          st          <= S_INIT_REF1;
        end
        S_INIT_REF1: begin
          if (timer == 0) begin cmd(CMD_REFRESH); timer <= 16'd8; st <= S_INIT_REF2; end
          else timer <= timer - 16'd1;
        end
        S_INIT_REF2: begin
          if (timer == 0) begin cmd(CMD_REFRESH); timer <= 16'd8; st <= S_INIT_MODE; end
          else timer <= timer - 16'd1;
        end
        S_INIT_MODE: begin
          if (timer == 0) begin
            cmd(CMD_LOADMODE);
            SDRAM_A  <= MODE;
            SDRAM_BA <= 2'd0;
            timer    <= 16'd4;
            st       <= S_IDLE;
          end else timer <= timer - 16'd1;
        end

        // ---------------- idle -----------------------------------------
        S_IDLE: begin
          SDRAM_DQML <= 1'b1;
          SDRAM_DQMH <= 1'b1;
          if (timer != 0) begin
            timer <= timer - 16'd1;         // honour tRC after the last access
          end else if (ref_due) begin
            // Rows are left open now, so every bank has to be precharged
            // before AUTO REFRESH.  Omitting this is the classic form of this
            // bug and it corrupts memory quietly rather than failing.
            cmd(CMD_PRECHARGE);
            SDRAM_A[10] <= 1'b1;            // all banks
            row_valid   <= 4'd0;
            timer       <= TRP_CLKS[15:0];
            st          <= S_PRE_ALL;
          end else if (req) begin
            // a byte write reads first; rmw_wr marks the write-back half, and
            // a refresh is free to slip in between the two -- req is held by
            // the same master until ack, so nothing else can take the bus.
            rd_pending <= rmw_wr ? 1'b0 : (~we | byte_wr);
            rmw_rd     <= rmw_wr ? 1'b0 : byte_wr;
            if (row_hit) begin
              // D7a skipped ACTIVE and tRCD.  D8b skips the deciding clock
              // too: on a hit there is nothing left to decide, so the CAS
              // goes out from here rather than from S_CMD one clock later.
              // Hits are 51.6-75.8 % of accesses depending on scene load
              // (A29, three frames), so this is most of a clock per read for
              // logic that was doing nothing.  The 71.7 % this used to quote was
              // the frozen counter of L20 describing the ROM download.
              if (!ctr_full) hit_a  <= hit_a  + 16'd1;
              SDRAM_A    <= {2'b00, 1'b0, a_col};   // A10 = 0, no auto pre
              SDRAM_BA   <= a_bank;
              if (rmw_wr ? 1'b0 : (~we | byte_wr)) begin
                cmd(CMD_READ);
                SDRAM_DQML <= 1'b0;
                SDRAM_DQMH <= 1'b0;
                st         <= S_CL1;
              end else begin
                cmd(CMD_WRITE);
                dq_oe      <= 1'b1;
                dq_out     <= rmw_wr ? rmw_data : din;
                SDRAM_DQML <= rmw_wr ? 1'b0 : ~ds[0];
                SDRAM_DQMH <= rmw_wr ? 1'b0 : ~ds[1];
                rmw_wr     <= 1'b0;
                ack        <= 1'b1;
                timer      <= TRC_AFTER_WR[15:0];
                st         <= S_IDLE;
              end
            end else if (row_conflict) begin
              if (!ctr_full) conf_a <= conf_a + 16'd1;
              cmd(CMD_PRECHARGE);
              SDRAM_A           <= 13'd0;   // A10 = 0 -> this bank only
              SDRAM_BA          <= a_bank;
              row_valid[a_bank] <= 1'b0;
              timer             <= TRP_CLKS[15:0] - 16'd1;
              st                <= S_PRE;
            end else begin
              if (!ctr_full) miss_a <= miss_a + 16'd1;
              cmd(CMD_ACTIVE);
              SDRAM_A           <= a_row;
              SDRAM_BA          <= a_bank;
              row_valid[a_bank] <= 1'b1;
              row_open[a_bank]  <= a_row;
              timer             <= TRCD_CLKS[15:0] - 16'd1;
              st                <= S_RCD;
            end
          end
        end

        S_REF_WAIT: begin
          if (timer == 0) st <= S_IDLE;
          else            timer <= timer - 16'd1;
        end

        // The bank was open on a different row.  tRP, then open the right one.
        S_PRE: begin
          if (timer == 0) begin
            cmd(CMD_ACTIVE);
            SDRAM_A           <= a_row;
            SDRAM_BA          <= a_bank;
            row_valid[a_bank] <= 1'b1;
            row_open[a_bank]  <= a_row;
            timer             <= TRCD_CLKS[15:0] - 16'd1;
            st                <= S_RCD;
          end else timer <= timer - 16'd1;
        end

        // Every bank precharged; tRP, then the refresh that was due.
        S_PRE_ALL: begin
          if (timer == 0) begin
            ref_due <= 1'b0;
            cmd(CMD_REFRESH);
            timer   <= 16'd6;               // tRFC
            st      <= S_REF_WAIT;
          end else timer <= timer - 16'd1;
        end

        // ---------------- one access -----------------------------------
        // tRCD, derived rather than assumed.  One state is already spent
        // getting here from S_IDLE, so this waits out the remainder.  When
        // TRCD_CLKS is 1 the timer is already 0 and this falls straight
        // through, which is exactly what the original did at 40 MHz.
        S_RCD: begin
          if (timer == 0) st <= S_CMD;
          else            timer <= timer - 16'd1;
        end

        S_CMD: begin
          // A10 = 0: do NOT auto precharge.  The row stays open for the next
          // access to the same bank, which is the whole of D7a.
          //
          // BA is driven here as well as at ACTIVE, because the row-hit path
          // reaches this state without ever passing through ACTIVE.
          SDRAM_A  <= {2'b00, 1'b0, a_col};
          SDRAM_BA <= a_bank;
          if (rd_pending) begin
            cmd(CMD_READ);
            SDRAM_DQML <= 1'b0;
            SDRAM_DQMH <= 1'b0;
            st         <= S_CL1;
          end else begin
            cmd(CMD_WRITE);
            dq_oe      <= 1'b1;
            // the write-back half of a byte write already holds a merged word,
            // so it goes down whole and does not depend on DQM at all
            dq_out     <= rmw_wr ? rmw_data : din;
            SDRAM_DQML <= rmw_wr ? 1'b0 : ~ds[0];   // DQM high masks the byte
            SDRAM_DQMH <= rmw_wr ? 1'b0 : ~ds[1];
            rmw_wr     <= 1'b0;
            ack        <= 1'b1;             // writes complete immediately
            timer      <= TRC_AFTER_WR[15:0];  // keep tRC clear before ACTIVE
            st         <= S_IDLE;
          end
        end

        // Read data return.  Count the clocks rather than trusting CL=2 to mean
        // "sample two states later", because it does not:
        //
        //   cycle N    st = S_CMD                     READ registered
        //   cycle N+1  READ on the pins;  the SDRAM samples it half a period
        //              in (SDRAM_CLK is 180 degrees out), so the part's command
        //              edge is at N+1.5
        //   N+3.5      CL=2 later the part starts driving DQ; tAC is measured
        //              from this edge, and DQ is held until N+4.5
        //   N+4.0      the only core clock edge inside that window
        //
        // so the latch has to be three states after S_CMD, not two.  It used to
        // be two and sim/tb_na2_sdram.sv reads back high-Z on every access --
        // the whole 68000 program ROM.  Nothing in a fitter run or in the boot
        // testbench (which swaps in a behavioural memory) can see this.
        S_CL1: st <= S_CL2;
        S_CL2: st <= S_CL3;
        S_CL3: begin
          if (rmw_rd) begin
            // R half of a byte write: merge, then go round again as a write.
            // No ack -- the caller sees one transaction.
            rmw_data <= {ds[1] ? din[15:8] : SDRAM_DQ[15:8],
                         ds[0] ? din[7:0]  : SDRAM_DQ[7:0]};
            rmw_rd   <= 1'b0;
            rmw_wr   <= 1'b1;
          end else begin
            dout <= SDRAM_DQ;
            ack  <= 1'b1;
          end
          // Zero again, and this time it is safe: sf_memarb now gates m_req
          // with ~m_ack (D8a), so `req` is physically low during the clock
          // `ack` is high and S_IDLE cannot see the transaction it just
          // finished.  The comment below is kept because it is the record of
          // why a timer was there at all, and of what happens without either
          // mechanism.
          //
          // sf_memarb registers `busy`, so it drops the grant on the clock
          // edge AFTER it sees m_ack.  `req` is therefore still high during
          // the clock in which ack is high.  With timer at 0, S_IDLE looks at
          // `req` in exactly that clock and issues the whole access a second
          // time; if the arbiter then hands the bus to another client, the
          // duplicate is in flight against a different address and returns
          // that client's data to this one.
          //
          // It was set to 0 here on the first cut of D7a and cost a hardware
          // run: SDRAM probe A read 0000 instead of 003B, the 68000 froze
          // after 261 reads, and the Z80 stall counter pinned -- while the
          // video counters kept incrementing, because they only count acks.
          //
          // The reason was already written down four lines above the
          // definition of TRC_AFTER_RD: "Never let it reach zero: S_IDLE
          // needs one state to notice the timer at all."
          timer <= 16'd0;
          // ---- D22b: issue the next read from here, not from S_IDLE -------
          //
          // Only with `handoff`.  The arbiter raises it, registered, exactly
          // when it took the offer and moved `sel`, so `addr` has been the
          // NEXT client's for this whole clock.  Without it the address is
          // still the one just read and issuing would repeat that read --
          // which is what `req` alone let happen three times.
          //
          // Narrow on purpose: a plain read, a row hit, no refresh due, no
          // byte-write merge.  Everything else goes back through S_IDLE, the
          // path that has been on hardware since D7a.
          if (chain_ok) begin
            if (!ctr_full) hit_a <= hit_a + 16'd1;
            SDRAM_A    <= {2'b00, 1'b0, a_col};   // A10 = 0, no auto precharge
            SDRAM_BA   <= a_bank;
            cmd(CMD_READ);
            SDRAM_DQML <= 1'b0;
            SDRAM_DQMH <= 1'b0;
            rd_pending <= 1'b1;
            rmw_rd     <= 1'b0;
            st         <= S_CL1;
          end else
          st    <= S_IDLE;
        end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
