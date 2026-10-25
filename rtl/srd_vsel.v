// ---------------------------------------------------------------------------------------------------------------------
// Super Real Darwin for MiSTer - Copyright (C) 2026 Eggsecutioner528
// Licensed under the GNU General Public License, version 2 or (at your option) any later version (see LICENSE).
// Any copy or derived work must keep this notice, name the author and be published with its complete source under the same license.
// Provenance mark GDM-14e473a7ba71
// ---------------------------------------------------------------------------------------------------------------------
// Game version selection for SRD. The download (srd_loader) leaves the program, character, MCU and sound ROMs of every version raw in the
// SDRAM staging area; this module copies the selected version from there into the block RAMs of the core, 8 bytes per SDRAM read, and holds the core
// in reset (busy) meanwhile. It runs when a download has just finished and every time the OSD version changes afterwards, so the version can be
// switched without a new download (about 25 ms). It also tells the graphics ROM which version's sprite rows to use (ver_l, stable while the core runs).
// Staging block of one version (0x2D000 bytes): main 000000-01FFFF (dy_00 then dy_01), character 020000-023FFF, MCU 024000-024FFF, sound 025000-02CFFF;
// the version v starts at v * 0x2D000 (see srd_loader.v). The core's program memory is banks 0-7 at 0x00000-0x1FFFF and the fixed ROM at 0x20000-0x27FFF.
module srd_vsel (
    input             clk,
    input             ioctl_download,
    input      [1:0]  ver_sel,              // OSD choice, 0 = World, 1 = Japan (2 and 3 are treated as 0)
    output reg        busy,                 // copying
    output            hold,                 // hold the core in reset: copying, or about to copy (no gap between the download and the copy)
    output reg [1:0]  ver_l,                // version in use (latched when the copy starts)

    // srd_gfxrom staging read port
    output reg        rr_req,
    output     [20:0] rr_addr,
    input             rr_ack,
    input      [63:0] rr_q,

    // destinations (same ports the download used to drive)
    output reg        mrom_we,
    output reg [17:0] mrom_wa,
    output reg [7:0]  mrom_wd,
    output reg        crom_we,
    output reg [13:0] crom_wa,
    output reg [7:0]  crom_wd,
    output reg        mcu_we,
    output reg [11:0] mcu_wa,
    output reg [7:0]  mcu_wd,
    output reg        snd_we,
    output reg [14:0] snd_wa,
    output reg [7:0]  snd_wd
);
    localparam [15:0] NBLK = 16'h05A00;                 // 0x2D000 / 8 blocks per version
    wire [1:0] sel = (ver_sel == 2'd1) ? 2'd1 : 2'd0;

    reg        dl_d = 1'b0, loaded = 1'b0;
    assign hold = busy | dl_d | (loaded & (sel != ver_l));
    reg [15:0] cnt = 16'd0;                             // block number inside the version
    reg [2:0]  bi = 3'd0;
    reg [63:0] data = 64'd0;
    reg        wr = 1'b0;                               // 0: wait for the read, 1: write the 8 bytes out
    wire [20:0] vb = (ver_l == 2'd1) ? 21'h02D000 : 21'd0;
    assign rr_addr = vb + {2'b00, cnt, 3'b000};

    wire [18:0] soff = {cnt[15:0], 3'b000} + {16'd0, bi};   // byte offset inside the version's staging block
    wire [7:0]  byt  = data[{bi, 3'b000} +: 8];

    always @(posedge clk) begin
        dl_d <= ioctl_download;
        mrom_we <= 1'b0; crom_we <= 1'b0; mcu_we <= 1'b0; snd_we <= 1'b0;
        if (!busy) begin
            if (!ioctl_download && (dl_d || (loaded && sel != ver_l))) begin
                busy <= 1'b1; ver_l <= sel; cnt <= 16'd0; wr <= 1'b0; rr_req <= 1'b1;
            end
        end else if (!wr) begin
            if (rr_ack) begin data <= rr_q; rr_req <= 1'b0; bi <= 3'd0; wr <= 1'b1; end
        end else begin
            if (soff < 19'h18000)      begin mrom_we <= 1'b1; mrom_wa <= soff[17:0];                  mrom_wd <= byt; end   // banks 0-5
            else if (soff < 19'h20000) begin mrom_we <= 1'b1; mrom_wa <= soff[17:0] + 18'h8000;       mrom_wd <= byt; end   // second half of dy_01: the fixed ROM at 0x20000
            else if (soff < 19'h24000) begin crom_we <= 1'b1; crom_wa <= soff[13:0];                  crom_wd <= byt; end
            else if (soff < 19'h25000) begin mcu_we  <= 1'b1; mcu_wa  <= soff[11:0];                  mcu_wd  <= byt; end
            else                       begin snd_we  <= 1'b1; snd_wa  <= soff[14:0] - 15'h5000;       snd_wd  <= byt; end
            bi <= bi + 1'd1;
            if (bi == 3'd7) begin
                wr <= 1'b0;
                if (cnt == NBLK - 1'd1) begin busy <= 1'b0; loaded <= 1'b1; end
                else begin cnt <= cnt + 1'd1; rr_req <= 1'b1; end
            end
        end
    end
    initial begin busy = 0; ver_l = 0; rr_req = 0; mrom_we = 0; crom_we = 0; mcu_we = 0; snd_we = 0; mrom_wa = 0; mrom_wd = 0; crom_wa = 0; crom_wd = 0;
                  mcu_wa = 0; mcu_wd = 0; snd_wa = 0; snd_wd = 0; end
endmodule
