//============================================================================
//  Shadow Force -- SDRAM arbiter
//
//  sf_sdram is a single-port controller.  Six things on this board want ROM
//  data, so something has to order them.  On the real PCB they do not
//  compete: each has its own mask ROM and its own pins.  Sharing one SDRAM is
//  a platform artefact, so the arbiter job is to make the sharing invisible
//  -- nobody may be starved long enough to change board behaviour.
//
//  Priority, highest first:
//
//    0  download   ROM loading; the CPU is held in reset, so it owns the bus
//    1  sprite     hard real-time: a line buffer must be full before the line
//    2  bg         the two background layers, fetched per line
//    3  fg         the text layer, fetched per line
//    4  oki        M6295 sample fetch, at the chip own rate -- about 25 k/s
//    5  z80        sound CPU program fetch.  This board runs the Z80 from
//                  SDRAM rather than BRAM (DECISIONS D2), unlike Power Spikes
//    6  cpu        stalls harmlessly (DTACK just comes later)
//
//  bg and fg have separate slots rather than sharing one, because they fetch
//  during the SAME line and a shared slot would need a mux that serialises
//  them by hand.  The arbiter already does that job.
//
//  Sprites and tiles outrank the CPU because a late graphics word is a
//  visible glitch on that scanline while a late CPU word is only a slower
//  CPU.  The Z80 outranks the 68000 because a stalled sound CPU shifts audio
//  timing, which is audible, and a stalled 68000 is not.
//
//  **All of that is a design choice, not a hardware fact** -- the real board
//  has no arbiter at all.  Power Spikes copy of this module carries a scar
//  worth reading before touching the order: its ADPCM client was moved twice
//  on guesses and both moves were reverted, because the real fault was a
//  client asking seventy times too often.  No arbiter order fixes that.
//  Measure first -- dbg_cpu_stall below, and dbg_z80_stall in sf_top.
//
//  Grant is held until the controller acks, so a client that raises req must
//  keep it up and keep its address stable until ack.  That is the same
//  contract sf_sdram itself has.
//============================================================================
`default_nettype none

module sf_memarb #(
    parameter int N   = 7,
    // Which client the stall counter watches.  A literal here silently
    // measured the wrong client when the client count changed.
    parameter int CPU_ID = N - 1
) (
    input  wire            clk,
    input  wire            rst,

    // --- client side (index 0 = highest priority) --------------------------
    input  wire [N-1:0]        req,
    // D15.  "After this ack I have another word of the SAME fetch, and its
    // address is already on `addr` next clock."  Asserting it keeps the
    // grant instead of handing it to the next client, which is the whole
    // change: a six-word tile fetch is issued as six words, not as six
    // words with five other clients' unrelated addresses between them.
    //
    // The contract is the caller's to keep.  A client that raises `hold`
    // and then does NOT drive its next address is granting itself a
    // duplicate access to a stale address -- exactly the fault D7a's first
    // cut produced from the other direction.  Groups must be BOUNDED for
    // the same reason: `hold` held forever starves every other client.
    input  wire [N-1:0]        hold,
    input  wire [25*N-1:0]     addr,     // flattened: word address per client
    input  wire [16*N-1:0]     din,
    input  wire [N-1:0]        we,
    input  wire [2*N-1:0]      ds,
    output reg  [N-1:0]        ack,
    output wire [15:0]         dout,     // shared: valid for the acked client

    // --- controller side ---------------------------------------------------
    output wire [24:0]     m_addr,
    output wire [15:0]     m_din,
    input  wire [15:0]     m_dout,
    output wire            m_req,
    output wire            m_we,
    output wire [1:0]      m_ds,
    input  wire            m_ack,
    // D22b.  "The read in flight acks next clock."  An OFFER: the controller
    // is in S_CL2 and knows.  The arbiter may decline it.
    input  wire            m_ack_early,
    // ...and this is the ACCEPTANCE, registered.  It is high exactly when the
    // arbiter took the offer, moved `sel`, and `m_addr` is therefore the NEXT
    // client's for the whole ack clock.
    //
    // The first cut of D22 had no such signal and the controller gated its
    // fast path on `req` instead.  `ack <= 1'b1` in S_CL3 is non-blocking, so
    // m_ack is still 0 there and `m_req = busy & (~m_ack | early)` is `busy`
    // REGARDLESS of early -- the fast path fired even when the arbiter had
    // declined, with the old client's address still on the bus, and issued
    // that read a second time.  Three bitstreams, three dead 68000s
    // (DEBUG_LOG A41).
    output wire            m_handoff,

    // --- observability -----------------------------------------------------
    input  wire            line_start,
    input  wire            frame,
    // D22b.  Was CPU stall clocks, which read FFFF on every frame ever
    // sampled.  Now: offers the controller made that this arbiter DECLINED --
    // ack_early raised while the winner was a holder, or nobody else was
    // asking, or a hand-over was already in flight.
    //
    // Those are exactly the clocks in which the first cut of D22 issued a
    // duplicate read, because the controller gated on `req` and `req` is high
    // for all of S_CL3 (DEBUG_LOG A41).  If this reads ZERO the fault being
    // fixed never happened and the interlock is not the fix.
    //
    // It lives here and not in sf_sdram because a second 16-bit debug route
    // from the controller to the overlay cost -0.388 ns on the HDMI clock,
    // twice, identically.  This path is already routed and already met timing.
    output reg  [15:0]     dbg_cpu_stall,

    // ---- what a line actually gets, measured where it is visible ----------
    //
    // sf_sdram's dbg_bus_work/dbg_bus_waste pair cannot answer this and the
    // hardware reading taken from it was misread.  Two independent faults:
    //
    //   * both fast-path commands are issued from S_IDLE -- CMD_READ on a row
    //     hit and CMD_ACTIVE on a miss -- so the controller's most productive
    //     clock is scored as "idle with a request waiting".  And the `work`
    //     term leads with `st == S_ACTIVE`, a state that is declared and never
    //     entered, so that term is always false.
    //   * the arbiter's ack bubble is invisible to it, because `req` there is
    //     m_req = busy & ~m_ack, which is deliberately LOW in exactly that
    //     clock.  The one thing the counter was quoted for is the one thing it
    //     cannot see.
    //
    // These two say it plainly instead.  `acks` is transactions completed in a
    // line and `busy_clks` is clocks in which any client had a request
    // outstanding, both published as the worst line of the frame, so
    // busy_clks / acks IS clocks-per-read with nothing inferred.  Both fit:
    // a line is 3584 clocks and cannot hold more than a few hundred reads.
    output reg  [15:0]     dbg_line_acks,  // completed reads, WORST line
    output reg  [15:0]     dbg_line_busy   // clocks with demand, that line
);

  // ---------------------------------------------------------------------
  // Winner selection.  Locked while a transaction is in flight so the
  // address the controller latched cannot change under it.
  // ---------------------------------------------------------------------
  reg              busy;
  reg  [$clog2(N)-1:0] sel;
  // The client the transaction NOW COMPLETING belongs to.  Once `sel` can move
  // before the ack, `ack[sel]` reaches the wrong one.
  reg  [$clog2(N)-1:0] ack_sel;
  reg              early;
  assign m_handoff = early;

  // lowest set bit of req
  reg  [$clog2(N)-1:0] pick;
  reg                  any;
  integer i;
  always @(*) begin
    pick = '0;
    any  = 1'b0;
    for (i = N-1; i >= 0; i = i - 1)
      if (req[i]) begin pick = i[$clog2(N)-1:0]; any = 1'b1; end
  end

  // D8a.  The winner used to be re-selected a clock AFTER busy dropped, so
  // every transaction paid a dead clock in which nothing could start.  It is
  // now selected on the ack clock itself.
  //
  // The client that just acked has to be masked out of that selection: it
  // does not drop `req` until it has SEEN the ack, so it is still asking
  // during exactly the clock the next winner is chosen, and would win again.
  reg  [$clog2(N)-1:0] pick_x;
  reg                  any_x;
  integer j;
  always @(*) begin
    pick_x = '0;
    any_x  = 1'b0;
    for (j = N-1; j >= 0; j = j - 1)
      if (req[j] && (j[$clog2(N)-1:0] != sel)) begin
        pick_x = j[$clog2(N)-1:0];
        any_x  = 1'b1;
      end
  end

  always @(posedge clk) begin
    if (rst) begin
      busy    <= 1'b0;
      sel     <= '0;
      ack_sel <= '0;
      early   <= 1'b0;
    end else if (!busy) begin
      early <= 1'b0;
      if (any) begin sel <= pick; busy <= 1'b1; ack_sel <= pick; end
    end else if (m_ack_early && !hold[sel] && any_x && !early) begin
      // Accept only when the winner is a DIFFERENT client.  A holder has not
      // seen its ack, so its address is still the word just read.
      ack_sel <= sel;
      sel     <= pick_x;
      early   <= 1'b1;
    end else if (m_ack) begin
      early   <= 1'b0;
      // D15.  The holder keeps the grant.  `sel` does not change, so this
      // adds nothing to the cone the reverted ack bypass died on
      // (m_ack -> priority encoder -> address mux -> row compare): it is a
      // one-bit mux on `sel` feeding a register enable, and on this branch
      // the address mux input is the one already selected.
      // ack_sel follows whoever owns the transaction STARTING, on every
      // branch -- updating it when one ENDS was D22's other bug.
      if (early)           begin busy <= 1'b1; ack_sel <= sel;    end
      else if (hold[sel])  begin busy <= 1'b1; ack_sel <= sel;    end
      else if (any_x)      begin busy <= 1'b1; sel <= pick_x;
                                 ack_sel <= pick_x;               end
      else                 busy <= 1'b0;
    end
  end

  // Gated by !m_ack, and this is load bearing.
  //
  // While `ack` is high the grant still belongs to the client being acked, so
  // a controller that looks at `req` in that clock sees a request it has just
  // finished and issues it a second time -- against whatever address the
  // arbiter hands over next.  That is DEBUG_LOG A8: SDRAM probe A came back
  // 0000 instead of 003B and the 68000 froze, while every layer's "lines
  // completed" counter kept climbing, because those count acks and not data.
  //
  // sf_sdram used to defend against this with a one-clock timer.  A timer is
  // a guess about someone else's timing; this is the fact itself.
  // ---- D13 second half: the ack clock is no longer thrown away -----------
  //
  // Everything above is still true, and the fix is not to stop hiding the
  // request but to make the ADDRESS correct during that clock.  On the ack
  // edge the arbiter already chooses the next winner as `pick_x`, and pick_x
  // excludes `sel` by construction -- so presenting pick_x's address with the
  // request still up cannot re-issue the client being acked.  A8's hazard is
  // removed by naming the right client rather than by naming nobody.
  //
  // `ack` stays decoded from the REGISTERED sel, so the acknowledgement still
  // reaches the client that just finished.
  //
  // Worth one clock of five on a row hit, which at the measured mix is 9.21
  // clocks per read down to about 8.2, and with the bank hash 5.94 down to
  // 4.94 -- 603 reads a line to 725, against an even line's 627 (D13).
  //
  // ONLY the different-client case.  The `!busy && any` fall-through that
  // would also remove the second bubble is deliberately left out: it lets a
  // client win back-to-back, and sf_tilemap's rom_addr is combinational from
  // `k` while `k` only updates on the ack edge, so accepting that client on
  // that edge samples the OLD address -- A8 exactly.  No arbiter expression
  // recovers an address the client has not computed yet.  Codex reviewed both
  // and rated the second's timing cone materially worse; they do not go in
  // together because the result could not be attributed.
  // ---- REVERTED 2026-09-03, on a timing failure Codex predicted -----------
  //
  // The bypass above presented pick_x's address during the ack clock instead
  // of blanking the request, and it is still logically sound -- pick_x cannot
  // be the client being acked, so A8 cannot recur.  It closed no timing.
  //
  // Built together with the bank hash, the core clock came back at
  // **setup slack -2.650 ns, TNS -38.571**, against 0.137 to 0.454 ns of
  // margin all session.  Codex reviewed this exact change, rated it "low
  // logical risk, medium payoff, MEANINGFUL TIMING RISK" because it adds
  // `m_ack -> any_x/pick_x -> address mux -> row compare -> command decision`
  // to a cone that was already the critical one, said "the existing 0.399 ns
  // historical slack is the likely falsifier", and said explicitly not to
  // combine it with another change because the result could not be attributed.
  //
  // I combined it anyway, so the failing build cannot say which of the two
  // did it.  Reverting this leaves the bank hash alone -- the larger win,
  // 457 to 603 reads a line against this one's 603 to 725, and two XORs deep
  // instead of a whole priority encoder.  If the hash alone closes timing,
  // that also answers which change was responsible.
  //
  // Not deleted, because it is worth retrying once the hash's own effect is
  // measured and if the line still comes up short: the fix would be to
  // REGISTER the next selection rather than compute it combinationally in the
  // ack clock, which costs the bubble back on a client change but keeps it on
  // the common case.
  // Gated off during an ack -- A8 -- except when the hand-over was ACCEPTED,
  // where m_addr is the next client's for the whole clock.  The controller
  // does not rely on this alone: it gates on m_handoff.
  assign m_req  = busy & (~m_ack | early);
  assign m_addr = addr[25*sel +: 25];
  assign m_din  = din [16*sel +: 16];
  assign m_we   = we  [sel];
  assign m_ds   = ds  [2*sel +: 2];
  assign dout   = m_dout;

  always @(*) begin
    ack = '0;
    if (busy && m_ack) ack[ack_sel] = 1'b1;   // not sel: see ack_sel above
  end

  // ---------------------------------------------------------------------
  // How long the CPU actually waits.  Root CLAUDE.md 6.5: a claim needs a
  // measurement, and "the CPU is not starved" is a claim.  CPU is client 3.
  // ---------------------------------------------------------------------
  localparam int CPU = CPU_ID;
  // An offer the controller made and this arbiter turned down.  Published per
  // frame like the other counters, so a quiet frame reads a small number and
  // a zero means the case never arises.
  wire declined = busy && m_ack_early && !(!hold[sel] && any_x && !early);
  reg [15:0] decl_acc;
  always @(posedge clk) begin
    if (rst) begin
      dbg_cpu_stall <= 16'd0;
      decl_acc      <= 16'd0;
    end else if (frame) begin
      dbg_cpu_stall <= decl_acc;
      decl_acc      <= 16'd0;
    end else if (declined && decl_acc != 16'hFFFF) begin
      decl_acc <= decl_acc + 16'd1;
    end
  end

  // The BUSIEST line of the frame, and this definition is the second attempt.
  //
  // The first picked the line with the FEWEST acks and called it the worst.
  // That selects the QUIETEST line -- a line nobody asked much of has few
  // completions -- and it duly reported 167 acks in 1110 of a line's 3584
  // clocks, which is a line at 31 % demand, not a starved one.  It also had no
  // per-frame reset, so it was a sticky all-time minimum that latched during
  // startup and could never move up again: exactly the "a mark that can only
  // move one way stops being a measurement once it has moved" that sf_dbg
  // already has written down about the PC water marks it deleted.
  //
  // The starved line is the one with the MOST demand, so that is what is
  // selected now, its ack count is carried with it, and both restart every
  // frame.  busy/acks on the published pair is clocks-per-read on the line
  // that actually hurts.
  reg  [15:0] acks_l, busy_l, peak_busy;
  wire bus_full = (busy_l == 16'hFFFF);
  always @(posedge clk) begin
    if (rst) begin
      acks_l <= 16'd0; busy_l <= 16'd0; peak_busy <= 16'd0;
      dbg_line_acks <= 16'd0; dbg_line_busy <= 16'd0;
    end else begin
      if (line_start) begin
        // A line whose counter SATURATED is not a measurement of that line --
        // it is the ROM download, during which the CRTC is held in reset so
        // line_start never pulses and busy_l runs free to FFFF.  Refusing to
        // publish it is what stops the download era from becoming the
        // permanent champion.
        // Three conditions, and the second and third were added on
        // 2026-09-04 after sim/tb_mem.sv hit the same hole three different
        // ways (DEBUG_LOG A48).
        //
        // `busy_l != FFFF` was the only guard, and it refuses exactly one
        // era: the ROM download, during which the CRTC is held so line_start
        // never pulses and the counter runs free to its maximum.  But
        // saturating is not what makes that era meaningless -- being an era
        // when the bus was UNAVAILABLE is.  Two others look nothing like
        // FFFF:
        //
        //   * sf_sdram counts INIT_US = 200 us from the fall of `init`, which
        //     is 3.1 lines.  Lines inside it show full demand and ZERO acks.
        //   * any demand before the FIRST line_start accumulates into one
        //     bucket, so the first published "line" can carry several lines'
        //     worth of clocks.
        //
        // Either one takes `peak_busy` and, being unbeatable by a real line,
        // never gives it back -- so row 22 reads a number from an era that
        // was not a measurement, for the whole run.  It has not happened on
        // hardware, where the CRTC and the download deassert together, which
        // is exactly why it is worth closing before something moves.
        //
        // `acks_l != 0`     the bus served nothing, so nothing was measured
        // `busy_l <= 3584`  a line cannot be longer than a line
        if (busy_l > peak_busy && busy_l != 16'hFFFF
            && acks_l != 16'd0 && busy_l <= 16'd3584) begin
          peak_busy     <= busy_l;
          dbg_line_acks <= acks_l;
          dbg_line_busy <= busy_l;
        end
        acks_l <= 16'd0; busy_l <= 16'd0;
      end else begin
        if (|ack)              acks_l <= acks_l + 16'd1;
        if (|req && !bus_full) busy_l <= busy_l + 16'd1;
      end

      // OUTSIDE the line_start branch, and that is the whole fix.
      //
      // The previous cut put this in the `else`, under a comment asserting
      // that "vblank_start lands mid-line, which is harmless".  It does not:
      // sf_crtc computes nh = (hcnt == H_TOTAL-1) ? 0 : hcnt+1 and raises
      // vblank_start on nh == 0, which is the SAME clock it raises line_start.
      // So the reset sat in the one branch that is skipped exactly when it
      // fires, peak_busy kept the FFFF it latched during the download, and
      // nothing could ever beat it -- all six frames of the run read the
      // identical impossible pair.  The code followed the comment and the
      // comment was wrong.
      //
      // Last in the block, so on the clock where both fire the restart wins.
      // That discards the vblank line's candidacy, which is a blanking line
      // and never the busiest one.
      if (frame) peak_busy <= 16'd0;
    end
  end

endmodule

`default_nettype wire
