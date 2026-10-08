//============================================================================
//  Shadow Force -- MiSTer target
//
//  Platform transport only.  The arcade board is rtl/sf_top.sv and knows
//  nothing about hps_io, ioctl or the MRA; root CLAUDE.md section 4 keeps
//  that vocabulary on this side of the boundary.
//
//  Structure, the PLL comments and the hps_io tie-offs are carried over from
//  projects/vsystem/power_spikes/targets/mister/PowerSpikes.sv, which carried
//  them from NA-1/NA-2.  Three families now use this shell unchanged in
//  substance; docs/FACTORY_REUSE_NOTES.md records that as a promotion
//  candidate.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Ports this core does not use /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

// No framebuffer: this game is horizontal, so nothing rotates and the qsf
// does not define MISTER_FB.  The FB_* ports therefore DO NOT EXIST --
// sys/emu_ports.vh declares them inside `ifdef MISTER_FB.  Assigning them
// anyway creates implicit nets that go nowhere and synthesis warns about
// each one, which is how Power Spikes found this.
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN,
        DDRAM_BE, DDRAM_WE, DDRAM_RD} = 0;

// Aspect ratio.  Nothing drives these by default and an undriven output is
// only a warning, so the picture would just come out the wrong shape.
// 320 x 240 on a 4:3 monitor is the original.
wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

assign VGA_F1      = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE   = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// The sound section is not built yet, so snd_l/snd_r are constant zero.
// AUDIO_S stays 1 because they are declared signed and will be signed when
// the YM2151 and the M6295 land.  MAME routes YM2151 channel 0 left and 1
// right and sends the M6295 to both, so this board is genuinely stereo and
// AUDIO_MIX stays 0.
assign AUDIO_S   = 1;
assign AUDIO_L   = snd_l;
assign AUDIO_R   = snd_r;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

`include "build_id.v"
localparam CONF_STR = {
	"ShadowForce;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[4:2],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	// *** DEFAULT ON during bring-up. ***
	// MiSTer clears every status bit on a fresh core load, so the DEFAULT is
	// what a session actually starts with -- and right now the overlay is the
	// only way to see anything at all, because the tilemap and sprite engines
	// do not exist yet.  Listing On first makes status[10]=0 mean On.  Flip
	// this to "Off,On" once the game renders: a debug aid that hides the
	// thing being debugged is worse than none (NA-1/NA-2 shipped a
	// screenshot of its own overlay once).
	"P1O[10],Debug overlay,On,Off;",
	// Pausing when the OSD opens is what everyone expects and nobody asks
	// for, so it defaults ON -- listing On first makes status[12]=0 mean
	// On.  It reuses a bit the overlay page freed.
	"-;",
	// 이 레인만 DIP 줄이 없었다.  .mra 는 <switches> 를 싣고 있고 프레임워크가
	// ioctl index 254 로 이미 보드에 전달하고 있었으므로, 이 한 줄은 그것을
	// **보이게 할 뿐** 새 배선이 아니다.  Service 가 여기 있다
	// (docs/OSD_POLICY.md 3절).
	"DIP;",
	"-;",
	// --- 표준 OSD, docs/OSD_POLICY.md -------------------------------------
	"O[12],Pause when OSD open,On,Off;",
	// There is no overlay page option any more.  All 48 rows are drawn at
	// once -- 192 of 240 lines -- because paging never bought anything and
	// twice hid the instruments that mattered:  status[13:12] delivered 3
	// when the .mra asked for 2, and rows 48-63 are all `default`, so every
	// row read 0000, which is exactly what a dead core looks like.  Two
	// hardware runs went into that.  An instrument behind a selector you
	// cannot read back is worse than no instrument.  Do not reinstate it.
	"P1O[11],Video source,Test pattern,Core;",
	// DIAGNOSTIC, and it is here because the person playing remembered
	// something no instrument recorded: before the OKI got its sample cache
	// (d234e57) the effects were LOUD and at the wrong moment, and after it
	// they are at the right moment and inaudible.  STATUS wrote down that
	// "the fix made it worse is evidence about the fix" and nothing came back
	// to it.  Off = bypass, which is the board exactly as it was before that
	// commit -- 60x refetch storm included.  Defaults to On (status[13]=0)
	// because On is what ships.
	"P1O[13],OKI sample cache,On,Off;",
	// All three are DIAGNOSTICS, defaulted by the .mra to what measurement
	// says is right today: mix x2 (attract already fills 16 bits at x2 and
	// clips 0.24 % of samples at x4), OKI x1 (the <<2 the chip's own source
	// implies), cache 4096.  They are here so the remaining question -- the
	// OKI reads 2.7x below MAME at the median and 1.8x at p90, which is not
	// the shape of a pure gain error -- can be settled by ear in ONE
	// bitstream instead of one build per guess.
	// BALANCE, not a master.  BGM is the YM2151 (music), SFX is the OKI
	// M6295 (hit sounds and the announcer).  Each scales ITS OWN source
	// before the sum, so moving one changes the balance rather than pushing
	// the whole mix at `sat16`.
	//
	// x1/x1 is MAME EXACTLY -- the driver routes both chips at 0.50 and
	// sums (shadfrce.cpp:830-835), which is (ym + oki<<4)/2, and that is
	// what these produce at their defaults.  So the accurate setting needs
	// nothing selected, which is the whole reason the master went away: the
	// dial it replaced had no setting BELOW twice MAME, so getting the
	// samples audible meant driving the sum into the clamp.  That is the
	// "먹먹한 소리" of 2026-09-06 and DEBUG_LOG A54.
	//
	// They are DIAGNOSTICS and a taste control, not accuracy: anything but
	// x1/x1 is deliberately not MAME.  Measured at x1/x1 on hardware, A58:
	// worst |mix| before the clamp 11,955 of 32,767 and nothing clamped, so
	// there is real headroom to spend on either dial.
	"P1O[15:14],BGM volume (YM2151),MAME x1,x2,x3,x4;",
	"P1O[17:16],SFX volume (M6295),MAME x1,x2,x3,x4;",
	// 위의 P1 항목들은 전부 프로브다.  첫 화면에는 플레이어가 쓸 것만 둔다
	// (docs/OSD_POLICY.md 6절).  status 비트는 하나도 안 옮겼다.
	"P1,Debug;",
	"-;",
	"R[0],Reset;",
	// *** jn 에 R 이 두 번 있었다 (Button 6 과 Pause). ***  같은 물리 버튼을
	// 두 항목에 걸면 한 번 눌러 둘 다 발동한다.
	//
	// 6버튼 게임에서 Pause 를 기본 미할당(`-`)으로 두는 것은 이 플랫폼의
	// 표준이지 이 코어의 타협이 아니다.  보드의 .mra 998 개를 세어 확인했다:
	// 6버튼 코어 53 개 중 51 개가 default="A,B,X,Y,L,R,Start,Select,-" 이고,
	// **Street Fighter 도 그쪽이다.**  R 이 두 번 들어간 소수파가 2 개인데
	// 이 파일이 그중 하나였다.  docs/OSD_POLICY.md 2.2절.
	//
	// 슬롯은 이름이 있으므로 플레이어가 매핑할 수 있고, OSD 의 자동 정지가
	// 기본 On 이라 매핑하지 않아도 멈출 수는 있다.
	// 이름을 .mra 와 맞췄다.  전에는 여기가 Attack/Jump/Special 이고 .mra 가
	// Punch/Kick/Jump 라서 같은 버튼을 두 이름으로 부르고 있었다.
	//
	// 2026-10-06: the Possess (P+K) macro slot that used to end this list is
	// removed (user: no convenience hotkeys in the release).  On the 3-button
	// sets possession is Punch+Kick pressed together, as on the PCB.
	"J1,Punch,Kick,Jump,Punch 2,Kick 2,Possess,Start,Coin,Pause;",
	"jn,A,B,X,Y,L,R,Start,Select,-;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire [21:0] gamma_bus;
wire [127:0] status;
wire  [1:0] buttons;

wire        ioctl_download;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire [15:0] ioctl_index;
wire        ioctl_wait;

wire [31:0] joystick_0, joystick_1;
wire [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR), .WIDE(0)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(),
	.joystick_3(),

	.ps2_key(ps2_key),

	// hps_io declares these inputs with no default, so leaving them open
	// makes them float.  NA-1/NA-2 lost a session to exactly that: an open
	// ioctl_wait goes onto HPS_BUS[37] as "core not ready" and hung the HPS
	// partway through the ROM load.  Tie every one of them off explicitly.
	.joystick_0_rumble(16'd0),
	.joystick_1_rumble(16'd0),
	.joystick_2_rumble(16'd0),
	.joystick_3_rumble(16'd0),
	.joystick_4_rumble(16'd0),
	.joystick_5_rumble(16'd0),
	.ps2_kbd_clk_in(1'b0),
	.ps2_kbd_data_in(1'b0),
	.ps2_kbd_led_status(3'd0),
	.ps2_kbd_led_use(3'd0),
	.ps2_mouse_clk_in(1'b0),
	.ps2_mouse_data_in(1'b0),
	.video_rotated(1'b0),
	.new_vmode(1'b0),
	// OSD defaults come from the .mra, not from a rebuild.  Bit 0 (Reset) is
	// masked off: seeding it would hold the core in reset from the moment the
	// .mra finished loading, which is a baffling way to find an .mra typo.
	.status_in({104'd0, mra_status[23:1], 1'b0}),
	.status_set(mra_status_set),
	.info_req(1'b0),
	.info(8'd0),
	.sd_lba('{default:32'd0}),
	.sd_blk_cnt('{default:6'd0}),
	.sd_rd(1'b0),
	.sd_wr(1'b0),
	.sd_buff_din('{default:8'd0}),
	.ioctl_upload(),
	.ioctl_upload_req(1'b0),
	.ioctl_upload_index(8'd0),
	.ioctl_din(8'd0)
);

///////////////////   .MRA-SUPPLIED OSD DEFAULTS   ///////////////////////
//
// MiSTer clears every status bit on a fresh arcade load, so the DEFAULT is
// what a session actually starts with.  Rebuilding a bitstream to flip a
// debug option costs the better part of an hour; editing three bytes in the
// .mra costs seconds.  Mechanism carried from NA-1/NA-2 via Power Spikes.
//
//   <rom index="1"><part>hh mm ll</part></rom>
//     hh = status[23:16]   mm = status[15:8]   ll = status[7:0]
//
// tools/build_rom.py generates that block; see OSD_DEFAULTS there.
reg [23:0] mra_status      = 24'd0;
reg        mra_status_seen = 1'b0;
reg        ioctl_dl_d      = 1'b0;
reg        mra_status_done = 1'b0;
reg        mra_status_set  = 1'b0;

always @(posedge clk_sys) begin
	mra_status_set <= 1'b0;

	// !ioctl_addr[26:2] so only the first FOUR bytes can land here.
	if (ioctl_wr && (ioctl_index == 16'd1) && !ioctl_addr[26:2]) begin
		case (ioctl_addr[1:0])
			2'd0: mra_status[23:16] <= ioctl_dout;
			2'd1: mra_status[15:8]  <= ioctl_dout;
			2'd2: begin mra_status[7:0] <= ioctl_dout; mra_status_seen <= 1'b1; end
			default: ;
		endcase
	end

	ioctl_dl_d <= ioctl_download;

	if (ioctl_dl_d && !ioctl_download && mra_status_seen && !mra_status_done) begin
		// Only when NO saved settings were loaded.  MiSTer loads <setname>.CFG
		// into status BEFORE the ROM download, and status_set makes Main replace
		// all 128 bits with status_in (Main_MiSTer user_io.cpp
		// check_status_change) -- so pushing the .mra defaults unconditionally
		// overwrote every saved OSD setting on every load ("settings do not
		// save", reported 2026-10-07).  A saved file has some bit of [127:1]
		// set; a fresh load has none.  [0] is the reset bit Main pulses.
		mra_status_set  <= ~|status[127:1];
		mra_status_done <= 1'b1;
	end
end

///////////////////////   CLOCKS   ///////////////////////////////
//
// 56.000 MHz, and both timing-critical board clocks divide from it exactly:
//     68000 / 4 = 14.000 MHz, pixel / 8 = 7.000 MHz.
// Both come off the board's single 28 MHz crystal, so unlike Power Spikes
// there is no fractional pixel enable.  DECISIONS D1.
//
// outclk_1 is the same frequency shifted half a period for SDRAM_CLK
// (-8929 ps at 56 MHz).
//
// NA-1/NA-2's worst bug was a PLL Quartus accepted, TimeQuest blessed and
// the fitter programmed with an out-of-range VCO, so the core clock never
// ran on hardware and nothing said a word.
//
// THIS CORE HIT THE SAME THING ON ITS FIRST FULL COMPILE.  The aux output
// was 280 MHz, and 56 and 280 both divide 560 exactly, so the fitter chose
// VCO = 560 -- below the 600 MHz minimum, unable to lock.  Fit, timing and
// assembly all reported zero errors and produced a 3 MB .rbf.  Only
// tools/check_pll.py said anything, because it reads the counters the fitter
// PROGRAMMED rather than the frequencies the design requested.
//
// The aux output is now 100 MHz: lcm(56, 100) = 1400 and 1400 is the only
// multiple of it inside 600-1600, so the solver has exactly one choice.
// DO NOT REMOVE THE CHECK, and do not "simplify" the aux frequency.

wire clk_sys, clk_sdram, clk_aux, pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.outclk_2(clk_aux),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram;

// clk_aux is the 100 MHz output that exists only to force the PLL solver
// into a legal VCO.  IT MUST HAVE A REAL LOAD.  Left unconnected, Quartus
// deletes the counter, re-solves the PLL with two outputs and is free to put
// the VCO somewhere else -- which is exactly what happened to Power Spikes,
// and tools/check_pll.py caught it with "the fitter programmed 2 outputs, 3
// were expected".
//
// So it drives a counter whose top bit is observable in the debug overlay
// (row 24, pll_alive).  That is a genuine instrument as well as a load: if
// pll_alive never toggles, the third output is not running.
reg [23:0] aux_cnt = 24'd0;
always @(posedge clk_aux) aux_cnt <= aux_cnt + 24'd1;

reg [2:0] aux_sync = 3'd0;
always @(posedge clk_sys) aux_sync <= {aux_sync[1:0], aux_cnt[23]};

// STICKY, and it has to be.
//
// aux_cnt[23] flips every 2^23 / 100 MHz = 84 ms, so the raw toggle
// `aux_sync[2] ^ aux_sync[1]` is high for ONE clk_sys cycle in roughly five
// million.  An overlay that samples it reads 0 essentially always -- which is
// exactly what happened on the first hardware run: the decoder reported "the
// PLL's third output is not running" about a core whose PLL had just passed
// check_pll and which was visibly running the game.
//
// An instrument that cries wolf is worse than no instrument, so this latches
// "the aux clock has ticked since reset" instead.  That is the question worth
// asking -- if the fitter deleted the counter or re-solved the PLL, this
// never sets.
reg pll_alive = 1'b0;
always @(posedge clk_sys) begin
	if (rst_sys)                        pll_alive <= 1'b0;
	else if (aux_sync[2] ^ aux_sync[1]) pll_alive <= 1'b1;
end

wire rst_sys = RESET | status[0] | buttons[1] | ~pll_locked;

// The core is held in reset while ROMs load.  The memory bus must NOT be:
// it is the thing doing the loading.
wire rst_mem = ~pll_locked;

///////////////////////   INPUT   ////////////////////////////////
//
// docs/HARDWARE.md section 6.  Everything is ACTIVE LOW.  The board's own
// bit order inside each player byte is
//
//     0 right  1 left  2 UP  3 DOWN  4 button1  5 button2  6 button3  7 start
//
// which is NOT MiSTer's order: MiSTer gives right, left, DOWN, UP in
// joystick[3:0].  Bits 2 and 3 are therefore crossed over on purpose below.
//
// From the J1 line above:
//   0 right  1 left  2 down  3 up
//   4 Punch  5 Kick  6 Jump  7 Punch2  8 Kick2  9 Possess
//   10 Start  11 Coin  12 Pause

wire [31:0] j1 = joystick_0;
wire [31:0] j2 = joystick_1;

wire [7:0] in_p1 = ~{ j1[10], j1[6], j1[5], j1[4], j1[2], j1[3], j1[1], j1[0] };
wire [7:0] in_p2 = ~{ j2[10], j2[6], j2[5], j2[4], j2[2], j2[3], j2[1], j2[0] };

// Buttons 4-6.  Unused on the World parent set (its EXTRA port is all
// IPT_UNUSED); wired anyway because shadfrceu reads them and the clone is
// then a .mra change rather than an RTL change.
wire [7:0] in_extra = ~{ 2'b00, j2[9], j2[8], j2[7], j1[9], j1[8], j1[7] };

// OTHER is entirely unused on every set.
wire [7:0] in_other = 8'hFF;

// SYSTEM: coin1, coin2, service1.  coin2 and service1 are only readable in
// test mode on real hardware, which is a game-side property, not ours.
wire [7:0] in_system = ~{ 5'b00000, m_service, j2[11], j1[11] };
wire       m_service = 1'b0;

// MISC.  Only bits 5:3 are read.  **Bit 4 must read 1**: MAME's comment says
// it "must be ACTIVE_LOW or 'shadfrcj' jumps to the end (code at 0x04902e)".
// Bit 2 is an IPT_CUSTOM that MAME itself marks "guess" and nothing reads.
wire [7:0] in_misc = 8'hFF;

// PAUSE.
//
// The PCB has no pause line -- this is a core convenience, so it gates the
// CLOCK ENABLE and nothing the hardware would recognise.  sf_top already
// takes a `pause` input and folds it into ce_en, which stops the 68000, the
// Z80 and both sound chips while the CRTC and the tilemap fetchers keep
// running.  That matters: pausing by stopping the video would black the
// screen, and a pause you cannot see is indistinguishable from a hang.
//
// Two sources, because they answer different needs.  Opening the OSD should
// stop the game whether or not anyone thought to ask, and a dedicated button
// is for when they did.  The button TOGGLES rather than holds, so it can be
// tapped.
//
// Coming out of a ROM download must never leave the core paused -- the CPU is
// held in reset through the load and a stuck pause afterwards looks exactly
// like the boot failures this project spent a day telling apart.
wire pause_btn = j1[12] | j2[12];
reg  pause_btn_d, pause_latch;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (ioctl_download)                  pause_latch <= 1'b0;
	else if (~pause_btn_d & pause_btn)   pause_latch <= ~pause_latch;
end

wire pause_core = pause_latch | (OSD_STATUS & ~status[12]);

// DIP switches arrive from the .mra <switches> block at ioctl index 254.
// SW1 is the low byte, SW2 the high byte; the board reads them active low.
// The MAME defaults are DSW1 = 0xFE (Demo Sounds ON) and DSW2 = 0xFF.
// docs/HARDWARE.md section 6 -- root CLAUDE.md 5.1 exists because Power
// Spikes lost hours to a Demo Sounds default.
reg [15:0] dsw = 16'hFFFE;
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 16'h00FE) && !ioctl_addr[26:1]) begin
		if (!ioctl_addr[0]) dsw[7:0]  <= ioctl_dout;
		else                dsw[15:8] <= ioctl_dout;
	end
end

///////////////////////   CORE   /////////////////////////////////

wire [24:0] mem_addr;
wire [15:0] mem_dout, mem_din;
wire        mem_req, mem_we, mem_ack;
wire        mem_ack_early, mem_handoff;   // D22b offer / acceptance
wire  [1:0] mem_ds;

wire [24:0] dl_addr;
wire [15:0] dl_data;
wire        dl_req, dl_ack, dl_active;

wire [7:0]  vid_r, vid_g, vid_b;
wire        ce_pix, hblank, vblank, hsync, vsync;
wire        dbg_halted_n;
wire sf_frame;          // vblank pulse out of sf_top, for sf_sdram's counters
wire signed [15:0] snd_l, snd_r;

sf_download u_download
(
	.clk(clk_sys),
	.rst(rst_mem),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),
	.dl_addr(dl_addr),
	.dl_data(dl_data),
	.dl_req(dl_req),
	.dl_ack(dl_ack),
	.dl_active(dl_active)
);

sf_top sf
(
	.clk(clk_sys),
	.rst(rst_sys),
	.mem_rst(rst_mem),
	.pause(pause_core),

	.mem_addr(mem_addr),
	.mem_din(mem_din),
	.mem_dout(mem_dout),
	.mem_req(mem_req),
	.mem_we(mem_we),
	.mem_ds(mem_ds),
	.mem_ack(mem_ack),
	.mem_ack_early(mem_ack_early),
	.mem_handoff(mem_handoff),

	.dl_active(dl_active),
	.dl_addr(dl_addr),
	.dl_data(dl_data),
	.dl_req(dl_req),
	.dl_ack(dl_ack),

	.in_p1(in_p1),
	.in_p2(in_p2),
	.in_extra(in_extra),
	.in_other(in_other),
	.in_system(in_system),
	.in_misc(in_misc),
	.dsw1(dsw[7:0]),
	.dsw2(dsw[15:8]),

	.red(vid_r), .green(vid_g), .blue(vid_b),
	.hsync(hsync), .vsync(vsync),
	.hblank(hblank), .vblank(vblank),
	.ce_pix(ce_pix),

	.snd_l(snd_l),
	.snd_r(snd_r),

	.dbg_enable(~status[10]),
	.pcm_bypass(status[13]),
	.cfg_ym_gain(status[15:14]),
	.cfg_oki_gain(status[17:16]),
	.pll_alive(pll_alive),
	.dl_index(ioctl_index[7:0]),
	.dbg_row_hit(sdram_row_hit),
	.dbg_row_miss(sdram_row_miss),
	.dbg_row_conflict(sdram_row_conflict),
	.dbg_bus_work(sdram_bus_work),
	.dbg_bus_waste(sdram_bus_waste),
	.dbg_frame(sf_frame),
	.dbg_halted_n(dbg_halted_n)
);

///////////////////////   SDRAM   ////////////////////////////////

reg  [3:0] sdram_init_cnt = 0;
wire       sdram_init = ~sdram_init_cnt[3];
always @(posedge clk_sys) begin
	if (!pll_locked)     sdram_init_cnt <= 0;
	else if (sdram_init) sdram_init_cnt <= sdram_init_cnt + 1'd1;
end

// Timing constants are DERIVED from CLK_HZ inside the module -- at 56 MHz
// one clock is not enough for tRCD/tRP, which is the assumption Power Spikes
// found buried in its inherited copy.  DECISIONS D3.
wire [15:0] sdram_row_hit, sdram_row_miss, sdram_row_conflict;
wire [15:0] sdram_bus_work, sdram_bus_waste;

sf_sdram #(.CLK_HZ(56_000_000)) u_sdram
(
	.clk        (clk_sys),
	.init       (sdram_init),
	.frame      (sf_frame),
	.addr       (mem_addr),
	.din        (mem_din),
	.dout       (mem_dout),
	.req        (mem_req),
	.we         (mem_we),
	.ds         (mem_ds),
	.ack        (mem_ack),
	.ack_early  (mem_ack_early),
	.handoff    (mem_handoff),
	.SDRAM_A    (SDRAM_A),
	.SDRAM_BA   (SDRAM_BA),
	.SDRAM_DQ   (SDRAM_DQ),
	.SDRAM_DQML (SDRAM_DQML),
	.SDRAM_DQMH (SDRAM_DQMH),
	.SDRAM_nCS  (SDRAM_nCS),
	.SDRAM_nWE  (SDRAM_nWE),
	.SDRAM_nRAS (SDRAM_nRAS),
	.SDRAM_nCAS (SDRAM_nCAS),
	.SDRAM_CKE  (SDRAM_CKE),

	// D7a made the controller keep rows open.  Whether that helps depends
	// entirely on the hit rate, which no amount of arithmetic settles --
	// so the counters go to the overlay and the board reports it.
	.dbg_row_hit      (sdram_row_hit),
	.dbg_row_miss     (sdram_row_miss),
	.dbg_row_conflict (sdram_row_conflict),
	.dbg_bus_work     (sdram_bus_work),
	.dbg_bus_waste    (sdram_bus_waste)
);

///////////////////////   VIDEO   ////////////////////////////////

wire [2:0] fx = status[4:2];

///////////////////////   VIDEO BISECTION   //////////////////////////////
//
// Carried over from Power Spikes, which needed it: that core came up on
// hardware with a completely blank frame -- no game, and not even the debug
// overlay, which paints its own colours and does not depend on the palette.
// That narrows the fault to "the video path is not sweeping at all", but it
// does not say WHICH half, the core's video or the target's wiring into
// arcade_video.
//
// So this is a bisection.  It generates its own timing from clk_sys with
// NO RESET AT ALL -- deliberately, because a stuck rst_sys is one of the two
// candidate causes and a test pattern that shared the suspect reset would
// prove nothing.  Selected by status[11], which the .mra can set, so
// switching costs an .mra edit rather than a rebuild.
//
//   bars visible  -> arcade_video, the scaler and the target wiring are fine,
//                    and the fault is inside sf_top
//   still blank   -> the fault is at the target level or in the clock itself
//
// The divider is /8 rather than Power Spikes' fractional accumulator,
// because 56/8 = 7.000 MHz is exact.
reg [2:0] tp_div = 3'd0;
reg       tp_ce  = 1'b0;
reg [8:0] tp_h   = 9'd0;
reg [8:0] tp_v   = 9'd0;

always @(posedge clk_sys) begin
	tp_div <= tp_div + 3'd1;
	tp_ce  <= (tp_div == 3'd7);
	if (tp_ce) begin
		if (tp_h == 9'd447) begin
			tp_h <= 9'd0;
			tp_v <= (tp_v == 9'd271) ? 9'd0 : tp_v + 9'd1;
		end else begin
			tp_h <= tp_h + 9'd1;
		end
	end
end

wire       tp_hb = (tp_h >= 9'd320);
wire       tp_vb = (tp_v < 9'd8) || (tp_v >= 9'd248);
wire       tp_hs = (tp_h >= 9'd344) && (tp_h < 9'd380);
wire       tp_vs = (tp_v >= 9'd254) && (tp_v < 9'd258);
// Coarse vertical bars plus a horizontal ramp: any sweep at all is obvious,
// and a frozen counter shows as a flat colour.
wire [7:0] tp_r = {8{tp_h[5]}};
wire [7:0] tp_g = {8{tp_v[5]}};
wire [7:0] tp_b = tp_h[7:0];

wire use_core = status[11];

wire        v_ce  = use_core ? ce_pix : tp_ce;
wire        v_hb  = use_core ? hblank : tp_hb;
wire        v_vb  = use_core ? vblank : tp_vb;
wire        v_hs  = use_core ? hsync  : tp_hs;
wire        v_vs  = use_core ? vsync  : tp_vs;
wire [23:0] v_rgb = use_core ? {vid_r, vid_g, vid_b} : {tp_r, tp_g, tp_b};

// 320 visible pixels.  WIDTH is what arcade_video uses for the "Original"
// aspect ratio; getting it wrong stretches the picture and nothing errors.
arcade_video #(.WIDTH(320), .DW(24)) arcade_video
(
	.*,
	.clk_video(clk_sys),
	.ce_pix(v_ce),
	.RGB_in(v_rgb),
	.HBlank(v_hb),
	.VBlank(v_vb),
	.HSync(v_hs),
	.VSync(v_vs),
	.fx(fx)
);

endmodule
