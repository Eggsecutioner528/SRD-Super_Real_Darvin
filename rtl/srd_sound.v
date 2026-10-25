// ---------------------------------------------------------------------------------------------------------------------
// Super Real Darwin for MiSTer - Copyright (C) 2026 Eggsecutioner528
// Licensed under the GNU General Public License, version 2 or (at your option) any later version (see LICENSE).
// Any copy or derived work must keep this notice, name the author and be published with its complete source under the same license.
// Provenance mark GDM-cb6a23f1d3e4
// ---------------------------------------------------------------------------------------------------------------------
// Super Real Darwin sound board, after MAME's dec8_state_base::dec8_s_map and srdarwin_state::srdarwin:
//   DECO 222 (a 6502 whose opcode fetches have bits 5 and 6 swapped) 1.5 MHz, YM2203 1.5 MHz, YM3812 3 MHz
//   0000-05FF RAM   2000-2001 YM2203 (write)   4000-4001 YM3812 (write)   6000 sound latch (read)   8000-FFFF ROM (32 KB)
// The main CPU's write to 2000 stores the command in the latch and gives the sound CPU an NMI that is released after 3 CPU cycles (MAME sound_w).
// Only the YM3812 drives the CPU IRQ. The CPU core is Jose Tejada's jt65c02 (JTCORES, GPL-3, with a DECO 222 opcode swap added), the chips jt03 / jtopl2.
`ifndef NMI_W
`define NMI_W 8'd96
`endif
module srd_sound (
    input             clk,                // 48 MHz
    input             rst,
    input      [7:0]  snd_cmd,
    input             snd_cmd_tog,
    input             rom_we,
    input      [14:0] rom_wa,
    input      [7:0]  rom_wd,
    // Sound Settings (OSD): volume index of the music (YM3812), the effects (YM2203 FM voices) and the whole mix, and the treble mode. Index 0 = 100 percent
    // = the original mix bit for bit; 1..3 boost (125, 150, 200 percent), 4..12 attenuate, 13 and up = off.
    input      [3:0]  vol_music, vol_fx, vol_master,
    input      [1:0]  treble,
    output signed [15:0] audio
);
    // clock enables: 6 MHz for the CPU core (it divides by 4 into the 1.5 MHz E clock), 1.5 MHz for the YM2203, 3 MHz for the YM3812
    reg [4:0] cdiv = 5'd0;
    always @(posedge clk) cdiv <= rst ? 5'd0 : cdiv + 1'd1;
    wire cen6   = (cdiv[2:0] == 3'd7);
    wire cen_opn = (cdiv == 5'd31);
    wire cen_opl = (cdiv[3:0] == 4'd15);

    wire [15:0] cpu_addr;
    wire  [7:0] cpu_dout;
    wire        cpu_wr, cpu_rd;
    reg   [7:0] cpu_din;
    wire        irq_n_opn, irq_n_opl;
    reg         nmi = 1'b0;
    reg   [7:0] nmi_cnt = 8'd0;
    reg         tog_d = 1'b0;

    // NMI: 3 CPU cycles (3 x 32 clocks of the 48 MHz clock) after every command write
    always @(posedge clk) begin
        tog_d <= snd_cmd_tog;
        if (rst) begin nmi <= 1'b0; nmi_cnt <= 8'd0; end
        else begin
            if (snd_cmd_tog != tog_d) begin nmi <= 1'b1; nmi_cnt <= `NMI_W; end
            else if (nmi_cnt != 0) begin nmi_cnt <= nmi_cnt - 1'd1; if (nmi_cnt == 8'd1) nmi <= 1'b0; end
        end
    end

    jt65c02 #(.DECO222(1)) u_cpu (
        .rst(rst), .clk(clk), .cen(cen6),
        .irq(~irq_n_opl), .nmi(nmi),
        .wr(cpu_wr), .rd(cpu_rd), .addr(cpu_addr), .din(cpu_din), .dout(cpu_dout)
    );

    // chip selects, registered one clock after the access starts (as in jtcop_snd)
    wire cpu_acc = cpu_rd | cpu_wr;
    reg  ram_cs = 0, opn_cs = 0, opl_cs = 0, latch_cs = 0, rom_cs = 0;
    always @(posedge clk) begin
        ram_cs <= 0; opn_cs <= 0; opl_cs <= 0; latch_cs <= 0;
        if (rst) rom_cs <= 0;
        else if (cpu_acc) begin
            rom_cs <= cpu_addr[15];
            if (!cpu_addr[15]) begin
                if (cpu_addr < 16'h0600)                         ram_cs   <= 1;
                if (cpu_addr[15:1] == 15'h1000)                  opn_cs   <= 1;      // 2000-2001
                if (cpu_addr[15:1] == 15'h2000)                  opl_cs   <= 1;      // 4000-4001
                if (cpu_addr == 16'h6000)                        latch_cs <= 1;
            end
        end
    end

    // ROM 32 KB and RAM 2 KB (0600-07FF unused by the game), registered reads
    (* ramstyle = "M10K" *) reg [7:0] rom [0:32767];
    reg [7:0] rom_q;
    always @(posedge clk) begin
        if (rom_we) rom[rom_wa] <= rom_wd;
        rom_q <= rom[cpu_addr[14:0]];
    end
    (* ramstyle = "M10K" *) reg [7:0] ram [0:2047];
    reg [7:0] ram_q;
    wire ram_we = ram_cs & cpu_wr;
    always @(posedge clk) begin
        if (ram_we) ram[cpu_addr[10:0]] <= cpu_dout;
        ram_q <= ram[cpu_addr[10:0]];
    end

    always @(*) begin
        cpu_din = rom_cs   ? rom_q :
                  ram_cs   ? ram_q :
                  latch_cs ? snd_cmd :
                  8'hff;
    end

    wire signed [15:0] fm_snd, opl_snd;
    wire        [9:0]  psg_snd;
    wire        [7:0]  nc_opn, nc_opl;
    jt03 u_ym2203 (
        .rst(rst), .clk(clk), .cen(cen_opn),
        .din(cpu_dout), .addr(cpu_addr[0]), .cs_n(~opn_cs), .wr_n(~cpu_wr),
        .dout(nc_opn), .irq_n(irq_n_opn),
        .IOA_in(8'd0), .IOB_in(8'd0), .IOA_out(), .IOB_out(),
        .psg_A(), .psg_B(), .psg_C(),
        .fm_snd(fm_snd), .psg_snd(psg_snd), .snd(), .snd_sample()
    );
    jtopl2 u_ym3812 (
        .rst(rst), .clk(clk), .cen(cen_opl),
        .din(cpu_dout), .addr(cpu_addr[0]), .cs_n(~opl_cs), .wr_n(~cpu_wr),
        .dout(nc_opl), .irq_n(irq_n_opl), .snd(opl_snd), .sample()
    );

    // Mix after MAME's routing: YM2203 FM 0.20, each SSG channel 0.23, YM3812 0.70. Starting gains (in 1/64) are Gondomania's fit scaled by the route ratios
    // (FM 54 * 0.20 / 0.40, OPL 29 * 0.70 / 0.50, SSG 13.5 * 0.23 / 0.20); to be trimmed against a MAME recording (tools/fit_audio_gains.py).
    // v1.0.1: the effects (YM2203 FM voices and SSG) are twice as loud as in v1.0.0 (FM 28 -> 56, SSG 960 -> 1920); the OSD Effects Volume now scales both.
    localparam signed [8:0] G_FM = 9'sd56, G_OPL = 9'sd94;   // the music (YM3812) is twice as loud as in v1.0.0 too
    localparam        [12:0] G_PSG = 13'd1920;
    // volume index -> gain in sixteenths (16 = 100 percent)
    function [5:0] gl(input [3:0] i);
        case (i)
            4'd0: gl = 6'd16;  4'd1: gl = 6'd20;  4'd2: gl = 6'd24;  4'd3: gl = 6'd32;
            4'd4: gl = 6'd14;  4'd5: gl = 6'd12;  4'd6: gl = 6'd10;  4'd7: gl = 6'd8;
            4'd8: gl = 6'd6;   4'd9: gl = 6'd4;   4'd10: gl = 6'd3;  4'd11: gl = 6'd2;
            4'd12: gl = 6'd1;  default: gl = 6'd0;
        endcase
    endfunction
    wire signed [6:0]  gf = $signed({1'b0, gl(vol_fx)});
    wire signed [6:0]  go = $signed({1'b0, gl(vol_music)});
    wire signed [6:0]  gm = $signed({1'b0, gl(vol_master)});
    wire signed [22:0] fm_p  = fm_snd  * gf;
    wire signed [22:0] opl_p = opl_snd * go;
    wire        [15:0] psg_p = psg_snd * gl(vol_fx);
    // The levels are static, so the chain is cut into register stages (the delay of a few 48 MHz clocks does not matter): level, mix, DC blocker, master, clip.
    reg  signed [17:0] fm_l = 18'sd0, opl_l = 18'sd0;                  // (x * 16) >>> 4 = x: index 0 leaves every source untouched
    reg  [10:0] psg_l = 11'd0;                                              // up to 1023 x 32 / 16: needs 11 bits at 200 percent
    reg  signed [19:0] mixs = 20'sd0;
    wire signed [27:0] mix = fm_l * G_FM + opl_l * G_OPL + $signed({1'b0, psg_l}) * $signed({1'b0, G_PSG});   // wide: the sum must not be cut before the shift
    always @(posedge clk) begin
        fm_l  <= fm_p  >>> 4;
        opl_l <= opl_p >>> 4;
        psg_l <= psg_p >> 4;                                        // the SSG is an effect too: it follows the Effects Volume
        mixs  <= mix >>> 6;
    end
    // DC blocker (the SSG output is unsigned and its own DC removal needs seconds to settle after power on; MAME's output is centred): one pole high
    // pass of about 4 Hz, updated at the 1.5 MHz enable
    reg signed [35:0] dc_acc = 36'sd0;
    wire signed [19:0] dc_lp = dc_acc >>> 16;
    always @(posedge clk) begin
        if (rst) dc_acc <= 36'sd0;
        else if (cen_opn) dc_acc <= dc_acc + mixs - dc_lp;
    end
    wire signed [20:0] outs = mixs - dc_lp;
    reg  signed [27:0] outm = 28'sd0;
    reg  signed [15:0] mono = 16'sd0;
    always @(posedge clk) begin
        outm <= (outs * gm) >>> 4;
        mono <= (outm > 28'sd32767) ? 16'sd32767 : (outm < -28'sd32768) ? -16'sd32768 : outm[15:0];
    end
    // Treble (OSD): Original passes the mix through untouched, Soft / Softer / Muffled run it through a one pole low pass (audio_lp.v, 3 MHz update)
    wire signed [15:0] lp_l, lp_r;
    audio_lp u_lp (.clk(clk), .ce(cen_opl), .mode(treble), .in_l(mono), .in_r(mono), .out_l(lp_l), .out_r(lp_r));
    assign audio = lp_l;
endmodule
