// ---------------------------------------------------------------------------------------------------------------------
// Super Real Darwin for MiSTer - Copyright (C) 2026 Eggsecutioner528
// Licensed under the GNU General Public License, version 2 or (at your option) any later version (see LICENSE).
// Any copy or derived work must keep this notice, name the author and be published with its complete source under the same license.
// Provenance mark GDM-d61b97b39879
// ---------------------------------------------------------------------------------------------------------------------
// ROM download for SRD: the HPS streams the MRA bytes (ioctl_addr / ioctl_dout / ioctl_wr), this module sends each byte where it belongs.
// Each MRA holds one version of the game (SRD World.mra, SRD Japan.mra). Layout of the stream (plain MAME file order, written by
// tools/make_mra.py):
//   000000-01FFFF  background tile ROM, four banks of 0x8000 bytes: dy_03.b4 chunk k (0x4000, "lo") then dy_02.b5 chunk k (0x4000, "hi") -> SDRAM tile rows
//   020000-04FFFF  sprite ROM, six files of 0x8000 bytes in MAME region order (dy_07, dy_06, dy_09, dy_08, dy_11, dy_10)  -> SDRAM sprite rows
//   then the block of the version (02D000 bytes) at 050000:
//     +000000-00FFFF  dy_00.b16 (banks 0 to 3 of the main CPU)
//     +010000-01FFFF  dy_01 (first half: banks 4 and 5, second half: the fixed ROM 8000-FFFF)
//     +020000-023FFF  character ROM dy_05.b6, 16 KB
//     +024000-024FFF  i8751 MCU ROM, 4 KB
//     +025000-02CFFF  sound CPU ROM dy_04.d7, 32 KB
// The staging area (SDRAM, bank 2) keeps the program, character, MCU and sound ROMs of both versions as a raw copy; srd_vsel copies the selected
// version from there into the block RAMs of the core every time the core restarts, so the version can be changed in the OSD without a new download.
// Graphics rows: the video block wants one 64 bit word per 16 pixel row holding the raw ROM bytes of that row (the pens are picked out in srd_video):
//   tile row (address {bank, tile, y} = 14 bits), byte 0 = bits 63:56:  lo0 hi0 lo1 hi1 lo2 hi2 lo3 hi3, group g = pixels 4g..4g+3 stored at
//     tile * 32 + y + (g & 1 ? 0x2000 : 0) + (g & 2 ? 16 : 0) inside the 0x4000 byte chunk,
//   sprite row (address {code, y} = 15 bits), byte 0 = bits 63:56:  p0 left, p0 right, p1 left, p1 right, p2 left, p2 right (left = pixels 0-7, stored 16
//     bytes after the right half), p0 = plane at region offset 0x10000, p1 = 0x20000, p2 = 0x00000.
module srd_loader (
    input             clk,
    input             ioctl_download,
    input             ioctl_wr,
    input      [24:0] ioctl_addr,
    input      [7:0]  ioctl_dout,
    output reg        ioctl_wait,

    // every byte goes through srd_gfxrom's write interface: hold gw_valid and the other gw_ outputs until gw_ack pulses
    output reg        gw_valid,
    output reg [1:0]  gw_kind,         // 0 = tile ROM row byte, 1 = sprite ROM row byte, 2 = raw byte in the staging area
    output reg [1:0]  gw_ver,          // version (sprite rows are kept once per version)
    output reg [20:0] gw_off,          // rows: {row (16 bits), byte index (3 bits)}; staging: byte address
    output reg [7:0]  gw_data,
    input             gw_ack
);
    localparam [24:0] V0 = 25'h050000, VS = 25'h02D000;

    wire [24:0] a = ioctl_addr;
    wire        in_tile = a < 25'h020000;
    wire        in_spr  = a >= 25'h020000 && a < V0;
    wire [24:0] b  = a - V0;
    wire [1:0]  v  = (a < V0) ? 2'd3 : (b < VS) ? 2'd0 : 2'd3;                                  // 3 = not the version block (an MRA carries one version)
    wire [24:0] r  = b - ((v == 2'd1) ? VS : 25'd0);                                            // offset inside the version block
    wire        in_raw = (v != 2'd3);
    wire [20:0] sadr = r[20:0] + ((v == 2'd1) ? 21'h02D000 : 21'd0);                            // staging area address

    // tile ROM byte: bank = a[16:15], hi = a[14], n = a[13:0] (offset inside the chunk), tile = n[12:5], y = n[3:0], group g = {n[4], n[13]}
    wire [1:0]  tbank = a[16:15];
    wire        thi   = a[14];
    wire [13:0] tn    = a[13:0];
    wire [2:0]  tbi   = {tn[4], tn[13], thi};                                         // byte index in the row word
    wire [13:0] trow  = {tbank, tn[12:5], tn[3:0]};
    // sprite ROM byte: o = a - 0x20000, plane file at o[17:16]: 0 = p2, 1 = p0, 2 = p1; n = o[15:0]: code = n[15:5], left half = n[4], y = n[3:0]
    wire [17:0] so    = a[17:0] - 18'h20000;
    wire [1:0]  spl   = (so[17:16] == 2'd0) ? 2'd2 : (so[17:16] == 2'd1) ? 2'd0 : 2'd1;
    wire [15:0] sn    = so[15:0];
    wire [2:0]  sbi   = {spl, ~sn[4]};                                                // left half = even byte of the pair
    wire [14:0] srow  = {sn[15:5], sn[3:0]};

    always @(posedge clk) begin
        if (ioctl_download && ioctl_wr) begin
            if (in_tile || in_spr) begin
                gw_valid <= 1'b1; gw_kind <= in_tile ? 2'd0 : 2'd1; gw_ver <= 2'd0; gw_data <= ioctl_dout;
                gw_off   <= in_tile ? {4'b0, trow[13:0], tbi[2:0]} : {3'b0, srow[14:0], sbi[2:0]};
                ioctl_wait <= 1'b1;
            end else if (in_raw) begin
                gw_valid <= 1'b1; gw_kind <= 2'd2; gw_ver <= v; gw_data <= ioctl_dout;
                gw_off   <= sadr;
                ioctl_wait <= 1'b1;
            end
        end
        if (gw_ack) begin gw_valid <= 1'b0; ioctl_wait <= 1'b0; end
    end
    initial begin gw_valid = 0; ioctl_wait = 0; gw_kind = 0; gw_ver = 0; gw_off = 0; gw_data = 0; end
endmodule
