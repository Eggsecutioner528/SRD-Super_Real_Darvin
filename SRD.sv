// ---------------------------------------------------------------------------------------------------------------------
// Additions and changes for the SRD core in this file: Copyright (C) 2026 Eggsecutioner528.
// The original notices of the file stay as they are below; the changes are licensed under the same license as the original.
// Provenance mark GDM-f5e1330f5ee3
// ---------------------------------------------------------------------------------------------------------------------
//============================================================================
//
//  SRD (Data East DECO8 hardware, 1987) for MiSTer, with CRT rotation.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign FB_FORCE_BLANK = 1'b0;

assign VGA_F1 = 0;
assign VGA_SCALER  = status[55];
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1;      // signed
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

// HDMI picture options (same menu bits and hub wiring as the GX7 cores):
//   Orientation (status[1]): Horizontal (0, default) = the picture is rotated in DDR3 so the vertical monitor game is upright on a landscape display;
//   Vertical (1) = raw passthrough, for a display that is itself mounted vertically.
//   Flip Monitor (status[2]) turns the picture 180 degrees, xor the game's own flip request (3830 bit 3 when its Flip Screen DIP is on).
//   Aspect ratio (status[4:3]): Original (4:3 monitor, 3:4 once rotated), Pixel Perfect (square pixels), Full Screen.
// SRD is a ROT270 game: the raw raster turned 90 degrees counter clockwise is the upright picture, so the default rotation is counter clockwise.
wire        orientation_vertical = status[1];
wire        no_rotate    = orientation_vertical;
wire        flip_monitor = status[2];
wire  [1:0] ar           = status[4:3];
wire [11:0] raw_arx = (ar == 2'd0) ? 12'd4 : (ar == 2'd1) ? 12'd16 : 12'd0;
wire [11:0] raw_ary = (ar == 2'd0) ? 12'd3 : (ar == 2'd1) ? 12'd15 : 12'd0;
wire [11:0] rot_arx = (ar == 2'd0) ? 12'd3 : (ar == 2'd1) ? 12'd15 : 12'd0;
wire [11:0] rot_ary = (ar == 2'd0) ? 12'd4 : (ar == 2'd1) ? 12'd16 : 12'd0;
assign VIDEO_ARX = no_rotate ? raw_arx : rot_arx;
assign VIDEO_ARY = no_rotate ? raw_ary : rot_ary;

// CRT rotation (analog output) through the DDR3 hub, independent of the HDMI options above.
wire        crt_rot_sel    = status[46];                 // CRT Orientation Horizontal (rotated)
wire        crt_flip_opt   = status[47];                 // CRT Flip (180 degrees), in both orientations
wire  [4:0] crt_size_idx   = status[52:48];              // 0..15 the listed sizes (default first, then larger, then smaller)
wire  [3:0] crt_size_n     = (crt_size_idx > 5'd15) ? 4'd0 : crt_size_idx[3:0];
wire  [3:0] crt_size       = (crt_size_n <= 4'd3) ? (4'd12 + crt_size_n) : (4'd15 - crt_size_n);
// CRT position: the V and H options always mean what you see on the CRT. Rotated, the horizontal option moves along the raster lines (hs shift);
// raw (a portrait CRT, raster up and down) the vertical option does.
wire  [3:0] crt_hs_step    = crt_rot_sel ? status[33:30] : status[29:26];
wire  [3:0] crt_vs_step    = crt_rot_sel ? status[29:26] : status[33:30];
// The hub's flip input means counter clockwise while rotating, and a 180 degree flip in the raw path. This game's default rotation is counter clockwise.
wire        crt_flip       = crt_rot_sel ? ~crt_flip_opt : crt_flip_opt;
wire  [7:0] crt_r, crt_g, crt_b;
wire        crt_hs, crt_vs, crt_de;
wire        crt_ready;
wire  [1:0] crt_status;

`include "build_id.v"
localparam CONF_STR = {
	"SRD;;",
	"-;",
	// The OSD font is plain ASCII (no kanji), so the Japanese title is written in letters.
	// The version (World or Japan) comes with the MRA that was loaded (SRD World.mra or SRD Japan.mra): to change it, load the other MRA.
	"-;",
	"P1,Video;",
	"P1O[1],HDMI Orientation,Horizontal,Vertical;",
	"P1O[2],Flip Monitor,Off,On;",
	"P1O[4:3],Aspect ratio,Original,Pixel Perfect,Full Screen;",
	"P1-;",
	// CRT (analog output): Vertical (raw) is the unrotated 15 kHz raster of the real board (a vertical monitor, or a CRT on its side). Horizontal
	// (rotated) rotates and scales the picture through a DDR3 buffer for a normally mounted CRT. Size picks the picture size (Auto = the largest that
	// fits). CRT Flip turns the CRT picture by 180 degrees in either orientation. Position shifts the sync and always means the direction you see on
	// the CRT in the chosen orientation.
	"P1O[46],CRT Orientation,Vertical (raw),Horizontal (rotated);",
	"P1O[47],CRT Flip,Off,On;",
	"P1O[52:48],CRT Size,195x208,202x216,210x224,217x232,187x200,180x192,172x184,165x176,157x168,150x160,142x152,135x144,127x136,120x128,112x120,105x112;",
	"P1O[53],CRT Aspect,Square pixels,Arcade 3:4;",
	"P1O[54],CRT Smoothing,On,Off;",
	"P1O[55],VGA Scaler,Off,On;",
	"P1O[29:26],CRT V Position,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15;",
	"P1O[33:30],CRT H Position,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15;",
	"P1-;",
	"P1O[60],SDRAM Burst Timing,Early,Late;",
	// Sound Settings: music (the YM3812) and effects (the YM2203) each have their own level, plus a master level. 100% is the level of the original mix
	// (bit for bit); 125% to 200% boost it. Treble is a low pass on the final output. Option values stay short (a value over 28 characters froze the OSD on hardware).
	"P3,Sound Settings;",
	"P3O[41:38],Master Volume,100%,125%,150%,200%,88%,75%,63%,50%,38%,25%,19%,13%,6%,Off;",
	"P3O[25:22],Music Volume,100%,125%,150%,200%,88%,75%,63%,50%,38%,25%,19%,13%,6%,Off;",
	"P3O[37:34],Effects Volume,100%,125%,150%,200%,88%,75%,63%,50%,38%,25%,19%,13%,6%,Off;",
	"P3O[8:7],Treble,Original,Soft,Softer,Muffled;",
	// DIP switches as in MAME's srdarwin and srdarwinj: with every option on its first entry they read the factory defaults. The game reads its switches
	// at boot only, so a change restarts the game. The coin options differ between the versions (hidden with the mask bit of the other version).
	"P2,DIP Switches;",
	"H3P2O[10:9],Coin A,1 Coin 2 Credits,1 Coin 3 Credits,1 Coin 4 Credits,1 Coin 6 Credits;",
	"H3P2O[12:11],Coin B,1 Coin 1 Credit,2 Coins 1 Credit,3 Coins 1 Credit,4 Coins 1 Credit;",
	"h3P2O[10:9],Coin A,1 Coin 1 Credit,1 Coin 2 Credits,1 Coin 3 Credits,2 Coins 1 Credit;",
	"h3P2O[12:11],Coin B,1 Coin 1 Credit,1 Coin 2 Credits,1 Coin 3 Credits,2 Coins 1 Credit;",
	"P2O[13],Demo Sounds,On,Off;",
	"P2O[14],Flip Screen,Off,On;",
	"P2O[15],Cabinet,Upright,Cocktail;",
	"P2-;",
	"P2O[17:16],Lives,3,5,1,28 (Cheat);",
	"P2O[19:18],Difficulty,Normal,Easy,Hard,Hardest;",
	"P2O[20],Bonus Life,Every 50k,Every 100k;",
	"P2O[21],After Stage 10,Back to Stage 1,Game Over;",
	"P2O[43],Allow Continue,Yes,No;",
	// Service Mode holds the service switch (i8751 port 3 bit 4) closed: the game starts in its test mode. Changing it restarts the game, like the real board
	// would after the service switch is thrown at power on. There is no Service button.
	"P2O[42],Service Mode,Off,On;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"v,1;",
	"J1,Button 1,Button 2,Start,Coin;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire [21:0] gamma_bus;
`ifdef VERILATOR
assign gamma_bus[20:0] = 21'd0;
`endif
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

// The MRA sends one byte on index 1: the version (0 World, 1 Japan). It only picks which coin options the OSD shows.
reg         mod_japan = 1'b0;
wire        ioctl_download;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;
wire [15:0] ioctl_index;
wire [31:0] joystick_0, joystick_1;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({12'd0, mod_japan, 3'b000}),      // bit 3: the Japanese version was loaded (mod byte of the MRA)

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.ioctl_index(ioctl_index),
	.ioctl_upload(),
	.ioctl_upload_req(1'b0),
	.ioctl_upload_index(8'd0),
	.ioctl_din(8'd0),

	.ps2_key(ps2_key)
);

always @(posedge clk_sys) if (ioctl_download && ioctl_wr && ioctl_index[7:0] == 8'd1 && ioctl_addr == 25'd0) mod_japan <= ioctl_dout[0];

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
wire sdram_clk_shifted;
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),           // 48 MHz
	.outclk_1(sdram_clk_shifted), // 48 MHz, phase shifted: SDRAM_CLK source
	.locked(pll_locked)
);

wire sys_reset = RESET | status[0] | buttons[1];
// held in reset while the ROMs download, while the selected game version is copied into the block RAMs, and until the PLL is locked
wire vsel_hold;
// A change of the Service Mode or of any DIP switch restarts the game (the game reads its switches at boot only), so the new setting applies at once.
wire [7:0] dsw0, dsw1;
reg  [7:0] dsw0_q = 8'd0, dsw1_q = 8'd0; reg svc_q = 1'b0;
always @(posedge clk_sys) begin dsw0_q <= dsw0; dsw1_q <= dsw1; svc_q <= status[42]; end
wire svc_chg = (dsw0 != dsw0_q) | (dsw1 != dsw1_q) | (status[42] != svc_q);
// Power down style reset. The real board's reset (a power on reset chip, 47 ohm and 4.7 uF into Schmitt inverters) lasts about 20 ms after the supply is good; here every
// reset request (OSD, download, version copy, Service Mode change, PLL) holds the whole core in reset for at least 100 ms, so every part restarts cleanly as after a power
// cycle (an OSD reset was seen to leave the music dropped for a few seconds with a short pulse).
wire reset_req = sys_reset | ioctl_download | vsel_hold | ~pll_locked | svc_chg;
reg [22:0] rst_cnt = 23'd0;
always @(posedge clk_sys) begin
	if (reset_req) rst_cnt <= 23'd4_800_000;      // 100 ms at 48 MHz
	else if (rst_cnt != 23'd0) rst_cnt <= rst_cnt - 1'd1;
end
wire reset = reset_req | (rst_cnt != 23'd0);

///////////////////////   ROM DOWNLOAD   ///////////////////////////////

// The MRA has one file: the ROM stream (index 0), decoded by address (tools/make_mra.py, layout in rtl/srd_loader.v).
wire rom_dl = ioctl_download & (ioctl_index[7:0] == 8'd0);

wire        mrom_we, crom_we, mcu_we, snd_we;
wire [17:0] mrom_wa;
wire  [7:0] mrom_wd, crom_wd, mcu_wd, snd_wd;
wire [13:0] crom_wa;
wire [14:0] snd_wa;
wire [11:0] mcu_wa;
wire        gw_valid, gw_ack;
wire  [1:0] gw_kind, gw_ver;
wire [20:0] gw_off;
wire  [7:0] gw_data;

srd_loader loader (
	.clk(clk_sys),
	.ioctl_download(rom_dl), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
	.gw_valid(gw_valid), .gw_kind(gw_kind), .gw_ver(gw_ver), .gw_off(gw_off), .gw_data(gw_data), .gw_ack(gw_ack)
);

// The download carries one version; this copies it from the staging area in SDRAM into the block RAMs of the core.
wire        vsel_busy, rr_req, rr_ack;
wire [20:0] rr_addr;
wire [63:0] rr_q;
wire  [1:0] ver_l;
srd_vsel vsel (
	.clk(clk_sys), .ioctl_download(rom_dl), .ver_sel(2'd0), .busy(vsel_busy), .hold(vsel_hold), .ver_l(ver_l),
	.rr_req(rr_req), .rr_addr(rr_addr), .rr_ack(rr_ack), .rr_q(rr_q),
	.mrom_we(mrom_we), .mrom_wa(mrom_wa), .mrom_wd(mrom_wd),
	.crom_we(crom_we), .crom_wa(crom_wa), .crom_wd(crom_wd),
	.mcu_we(mcu_we), .mcu_wa(mcu_wa), .mcu_wd(mcu_wd),
	.snd_we(snd_we), .snd_wa(snd_wa), .snd_wd(snd_wd)
);

///////////////////////   GRAPHICS ROM IN SDRAM   ///////////////////////////////

wire [15:0] tile_row_addr, spr_row_addr;
wire [63:0] tile_row_q, spr_row_q;
wire        tile_ok, spr_ok;
wire [24:0] sd_addr;
wire [15:0] sd_din, sd_dout;
wire        sd_we, sd_rdburst, sd_ready, sd_burst_ready;
wire [255:0] sd_burst_dout;

srd_gfxrom gfxrom (
	.clk(clk_sys), .rst(reset),
	.tile_row_addr(tile_row_addr), .tile_row_q(tile_row_q), .tile_ok(tile_ok),
	.spr_row_addr(spr_row_addr), .spr_row_q(spr_row_q), .spr_ok(spr_ok), .spr_ver(ver_l),
	.gw_valid(gw_valid), .gw_kind(gw_kind), .gw_ver(gw_ver), .gw_off(gw_off), .gw_data(gw_data), .gw_ack(gw_ack),
	.rr_req(rr_req), .rr_addr(rr_addr), .rr_q(rr_q), .rr_ack(rr_ack),
	.sd_addr(sd_addr), .sd_din(sd_din), .sd_we(sd_we), .sd_rdburst(sd_rdburst),
	.sd_ready(sd_ready), .sd_burst_dout(sd_burst_dout), .sd_burst_ready(sd_burst_ready)
);

sdram sdram_inst (
	.init(~pll_locked),
	.clk(clk_sys),
	.sdram_clk_in(sdram_clk_shifted),

	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),

	.wtbt(2'b00),
	.addr(sd_addr),
	.dout(sd_dout),
	.din(sd_din),
	.we(sd_we),
	.rd(1'b0),
	.ready(sd_ready),
	.rdburst(sd_rdburst),
	.burst_words_m1(4'd3),
	.burst_dout(sd_burst_dout),
	.burst_ready(sd_burst_ready),
	.burst_early(~status[60])
);

///////////////////////   i8751 MCU   ///////////////////////////////

// 8 MHz crystal as a clock enable of the 48 MHz clock; jtframe_8751mcu divides it by 12 into machine cycles.
reg [2:0] mcen_cnt = 0;
always @(posedge clk_sys) mcen_cnt <= (mcen_cnt == 3'd5) ? 3'd0 : mcen_cnt + 1'd1;
wire mcu_cen = (mcen_cnt == 3'd0);
wire [7:0] mcu_p0_o, mcu_p1_o, mcu_p2_o, mcu_p3_o;
wire [7:0] mcu_p0_i, mcu_p1_i, mcu_p2_i, mcu_p3_i;
wire       mcu_int0n, mcu_int1n;

jtframe_8751mcu #(.DIVCEN(1)) u_mcu (
	.rst(reset), .clk(clk_sys), .cen(mcu_cen),
	.int0n(mcu_int0n), .int1n(mcu_int1n),
	.p0_i(mcu_p0_i), .p1_i(mcu_p1_i), .p2_i(mcu_p2_i), .p3_i(mcu_p3_i),
	.p0_o(mcu_p0_o), .p1_o(mcu_p1_o), .p2_o(mcu_p2_o), .p3_o(mcu_p3_o),
	.x_din(8'hff), .x_dout(), .x_addr(), .x_wr(), .x_acc(),
	.clk_rom(clk_sys), .prog_addr(mcu_wa), .prom_din(mcu_wd), .prom_we(mcu_we)
);

///////////////////////   SOUND   ///////////////////////////////

wire [7:0] snd_cmd; wire snd_cmd_tog;
wire signed [15:0] snd_audio;
srd_sound sound (
	.clk(clk_sys), .rst(reset),
	.snd_cmd(snd_cmd), .snd_cmd_tog(snd_cmd_tog),
	.rom_we(snd_we), .rom_wa(snd_wa), .rom_wd(snd_wd),
	.vol_music(status[25:22]), .vol_fx(status[37:34]), .vol_master(status[41:38]),
	.treble(status[8:7]),
	.audio(snd_audio)
);
assign AUDIO_L = snd_audio;
assign AUDIO_R = snd_audio;

///////////////////////   INPUTS AND DIP SWITCHES   ///////////////////////////////

// DIP switches as MAME's srdarwin / srdarwinj read them (see the menu above for how each option maps; every option's first entry is the factory default).
// Coin A and B: the raw value is the complement of the menu index in both versions (World and Japan list them in different orders in the menu text).
assign dsw0 = {status[15], ~status[14], ~status[13], 1'b1, ~status[12:11], ~status[10:9]};
assign dsw1 = {~status[43], 1'b1, ~status[21], ~status[20], ~status[19:18], ~status[17:16]};

// Standard arcade keyboard keys (as MAME): 5 and 6 coins, 1 and 2 starts, arrows, Ctrl and Alt for player 1 (decoded from the PS/2 key events the framework delivers).
// Service is the OSD DIP option Service Mode.
reg        k_coin1 = 0, k_coin2 = 0, k_st1 = 0, k_st2 = 0, k_stb = 0;
reg        k_up = 0, k_dn = 0, k_lf = 0, k_rt = 0, k_b1 = 0, k_b2 = 0;
always @(posedge clk_sys) if (ps2_key[10] != k_stb) begin
	k_stb <= ps2_key[10];
	case (ps2_key[8:0])
		9'h02E: k_coin1 <= ps2_key[9];
		9'h036: k_coin2 <= ps2_key[9];
		9'h016: k_st1   <= ps2_key[9];
		9'h01E: k_st2   <= ps2_key[9];
		9'h175: k_up    <= ps2_key[9];
		9'h172: k_dn    <= ps2_key[9];
		9'h16B: k_lf    <= ps2_key[9];
		9'h174: k_rt    <= ps2_key[9];
		9'h014: k_b1    <= ps2_key[9];
		9'h011: k_b2    <= ps2_key[9];
		default: ;
	endcase
end
// MiSTer pad bits: 0 right, 1 left, 2 down, 3 up, then the J1 buttons in menu order: 4 Button 1, 5 Button 2, 6 Start, 7 Coin.
wire [7:0] p1 = joystick_0[7:0] | {k_coin1, k_st1, k_b2, k_b1, k_up, k_dn, k_lf, k_rt};
wire [7:0] p2 = joystick_1[7:0] | {k_coin2, k_st2, 6'd0};
// IN0 (3801): player 1 right left down up (MAME order: right, left, up, down), button 1, button 2, start 1, start 2 (active low).
// IN1 (3802): the cocktail player 2 the same way (the vblank flag replaces bit 6).
wire [7:0] in0 = ~{p2[6], p1[6], p1[5], p1[4], p1[2], p1[3], p1[1], p1[0]};
wire [7:0] in1 = ~{2'b00, p2[5], p2[4], p2[2], p2[3], p2[1], p2[0]};
// i8751 port 3: bit 4 service, bit 5 coin 1, bit 6 coin 2, bit 7 coin 3 (active low, the low nibble reads as ones)
wire [7:0] coin_p3 = {1'b1, ~p2[7], ~p1[7], ~status[42], 4'hf};

///////////////////////   THE GAME BOARD   ///////////////////////////////

// Sync pulse positions on the 384 x 272 raster. Placeholders for now (front porch 40, pulse 32, back porch 56 pixels; vertical 4 lines after the
// picture, 3 lines long), to be measured against the original board; the CRT position options shift them.
wire [5:0]  crt_h_shift = {crt_hs_step, 1'b0} + crt_hs_step;           // 3 pixel clocks per step earlier
wire [8:0]  hs_start = 9'd296 - {3'd0, crt_h_shift};
wire [8:0]  hs_end   = 9'd328 - {3'd0, crt_h_shift};
wire [9:0]  vs_s_raw = 10'd252 + {5'd0, crt_vs_step, 1'b0};            // 2 lines later per step
wire [8:0]  vs_start = (vs_s_raw >= 10'd272) ? vs_s_raw - 10'd272 : vs_s_raw[8:0];
wire [9:0]  vs_e_raw = vs_s_raw + 10'd3;
wire [8:0]  vs_end   = (vs_e_raw >= 10'd272) ? vs_e_raw - 10'd272 : vs_e_raw[8:0];

wire [7:0] video_r, video_g, video_b;
wire       video_hs, video_vs, video_hblank, video_vblank, video_de;
wire       ce_pix, vbl_cpu, flip_screen_req;
wire        vbl_start;

srd_main main (
	.clk(clk_sys), .rst(reset), .init_h(9'd6), .init_v(9'd248),
	.mrom_we(mrom_we), .mrom_wa(mrom_wa), .mrom_wd(mrom_wd),
	.crom_we(crom_we), .crom_wa(crom_wa), .crom_wd(crom_wd),
	.tile_row_addr(tile_row_addr), .tile_row_q(tile_row_q), .tile_ok(tile_ok),
	.spr_row_addr(spr_row_addr), .spr_row_q(spr_row_q), .spr_ok(spr_ok),
	.dsw0(dsw0), .in0(in0), .in1(in1), .dsw1(dsw1),
	.coin_p3(coin_p3),
	.mcu_p0_o(mcu_p0_o), .mcu_p1_o(mcu_p1_o), .mcu_p2_o(mcu_p2_o), .mcu_p3_o(mcu_p3_o),
	.mcu_p0_i(mcu_p0_i), .mcu_p1_i(mcu_p1_i), .mcu_p2_i(mcu_p2_i), .mcu_p3_i(mcu_p3_i),
	.mcu_int0n(mcu_int0n), .mcu_int1n(mcu_int1n),
	.snd_cmd(snd_cmd), .snd_cmd_tog(snd_cmd_tog),
	.hs_start(hs_start), .hs_end(hs_end), .vs_start(vs_start), .vs_end(vs_end),
	.pxl_cen(ce_pix), .r(video_r), .g(video_g), .b(video_b),
	.hs(video_hs), .vs(video_vs), .hblank(video_hblank), .vblank(video_vblank), .de(video_de),
	.vbl_start(vbl_start), .vbl_cpu(vbl_cpu),
	.flip_screen(flip_screen_req)
);

///////////////////////   VIDEO OUTPUT   ///////////////////////////////

wire [7:0] av_vga_r, av_vga_g, av_vga_b;
wire       av_vga_hs, av_vga_vs, av_vga_de;

arcade_video #(256, 24) arcade_video (
	.clk_video(clk_sys),
	.ce_pix(ce_pix),
	.RGB_in({video_r, video_g, video_b}),
	.HBlank(video_hblank),
	.VBlank(video_vblank),
	.HSync(video_hs),
	.VSync(video_vs),
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(av_vga_r),
	.VGA_G(av_vga_g),
	.VGA_B(av_vga_b),
	.VGA_HS(av_vga_hs),
	.VGA_VS(av_vga_vs),
	.VGA_DE(av_vga_de),
	.VGA_SL(VGA_SL),
	.fx(3'b000),
	.forced_scandoubler(1'b0),     // the analog port always carries the raw 15 kHz raster, as on the real board
	.gamma_bus(gamma_bus)
);

// The analog pins always come from the hub: the rotated picture while CRT Orientation is Horizontal, otherwise the same raw raster.
assign VGA_R  = crt_r;
assign VGA_G  = crt_g;
assign VGA_B  = crt_b;
assign VGA_HS = crt_hs;
assign VGA_VS = crt_vs;
assign VGA_DE = crt_de;

// The game's own flip request (3830 bit 3, set by the game when its Flip Screen DIP is on) and the OSD Flip Monitor are combined with an xor.
// While rotating, the hub's rotate_ccw is the direction: this game's default is counter clockwise, a flip turns it clockwise. In the raw path the
// flip is a 180 degree flip.
wire effective_flip = flip_monitor ^ flip_screen_req;
wire video_rotated;

ddr_rotate_hub #(.NH(240)) ddr_rotate_hub (
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(av_vga_r),
	.VGA_G(av_vga_g),
	.VGA_B(av_vga_b),
	.VGA_HS(av_vga_hs),
	.VGA_VS(av_vga_vs),
	.VGA_DE(av_vga_de),
	.rotate_ccw(~effective_flip),
	.no_rotate(no_rotate),
	.flip(effective_flip),
	.video_rotated(video_rotated),
	.FB_EN(FB_EN),
	.FB_FORMAT(FB_FORMAT),
	.FB_WIDTH(FB_WIDTH),
	.FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE),
	.FB_STRIDE(FB_STRIDE),
	.FB_VBL(FB_VBL),
	.FB_LL(FB_LL),
	.DDRAM_CLK(DDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE),
	.DDRAM_RD(DDRAM_RD),
	.crt_en(crt_rot_sel),
	.crt_flip(crt_flip),
	.crt_size(crt_size),
	.crt_sq(~status[53]),
	.crt_smooth(~status[54]),
	.crt_hpos(5'd16),            // picture position comes from the sync shift (CRT Position options)
	.crt_vpos(5'd16),
	.crt_r(crt_r),
	.crt_g(crt_g),
	.crt_b(crt_b),
	.crt_hs(crt_hs),
	.crt_vs(crt_vs),
	.crt_de(crt_de),
	.crt_ready(crt_ready),
	.crt_status(crt_status)
);

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER    = act_cnt[26]  ? act_cnt[25:18]  > act_cnt[7:0]  : act_cnt[25:18]  <= act_cnt[7:0];

endmodule
