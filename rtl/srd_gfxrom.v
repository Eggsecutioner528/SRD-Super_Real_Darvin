// ---------------------------------------------------------------------------------------------------------------------
// Super Real Darwin for MiSTer - Copyright (C) 2026 Eggsecutioner528
// Licensed under the GNU General Public License, version 2 or (at your option) any later version (see LICENSE).
// Any copy or derived work must keep this notice, name the author and be published with its complete source under the same license.
// Provenance mark GDM-5970499de069
// ---------------------------------------------------------------------------------------------------------------------
// Graphics ROM rows in SDRAM for SRD: the tile and sprite ROMs live in SDRAM in the row format of tools/make_roms_srd.py
// (64 bits per 16 pixel row, address {tile, row}; the words hold the raw ROM bytes of the row, see srd_loader.v). Jobs:
//   1. download: single bytes arrive in MAME region order and are written (one byte write each, scattered) to their place in the row format,
//   2. fetch: the video block asks for rows through one entry caches (tile and sprite) and waits for tile_ok / spr_ok after every address change,
//   3. staging: the program, character, MCU and sound ROMs of every game version are kept raw in SDRAM (bank 2); srd_vsel reads them back in
//      8 byte blocks (rr_ port) to fill the block RAMs of the core for the selected version.
// Uses rtl/sdram.sv unchanged (the GX7 cores' proven controller) in 8 bit write mode and with its 4 word burst read.
//
// SDRAM layout: bank 0 = tile rows, bank 1 = sprite rows (0x40000 bytes),
// bank 2 = staging area (raw bytes, srd_loader's layout). Row byte address = {row, 3'b000} + byte index of the 8 byte row word (index 0 = bits 63:56).
// Even byte addresses sit in the low byte of the 16 bit SDRAM word.
module srd_gfxrom (
    input             clk,
    input             rst,

    // video block side
    input      [15:0] tile_row_addr,
    output     [63:0] tile_row_q,
    output            tile_ok,
    input      [15:0] spr_row_addr,
    output     [63:0] spr_row_q,
    output            spr_ok,
    input      [1:0]  spr_ver,             // version whose sprite rows the video block reads (hold it while the core runs)

    // download side: hold gw_valid and the other gw_ inputs until gw_ack pulses
    input             gw_valid,
    input      [1:0]  gw_kind,             // 0 = tile ROM, 1 = sprite ROM, 2 = raw byte in the staging area
    input      [1:0]  gw_ver,
    input      [20:0] gw_off,              // rows: {row (16 bits), byte index (3 bits)}; staging: byte address
    input      [7:0]  gw_data,
    output reg        gw_ack,

    // staging area read: hold rr_req until rr_ack pulses; rr_q then holds the 8 bytes at rr_addr (byte i = rr_q[8*i +: 8])
    input             rr_req,
    input      [20:0] rr_addr,
    output reg [63:0] rr_q,
    output reg        rr_ack,

    // rtl/sdram.sv
    output reg [24:0] sd_addr,
    output reg [15:0] sd_din,
    output reg        sd_we,
    output reg        sd_rdburst,
    input             sd_ready,
    input      [255:0] sd_burst_dout,
    input             sd_burst_ready
);
    reg [63:0] tq = 64'd0, sq = 64'd0;
    reg [15:0] ttag = 16'd0, stag = 16'd0;
    reg [1:0]  sver = 2'd0;                       // version of the cached sprite row
    reg        tvalid = 1'b0, svalid = 1'b0;
    assign tile_row_q = tq;
    assign spr_row_q  = sq;
    assign tile_ok = tvalid && ttag == tile_row_addr;
    assign spr_ok  = svalid && stag == spr_row_addr && sver == spr_ver;

    wire [63:0] row_in = {sd_burst_dout[7:0],   sd_burst_dout[15:8],  sd_burst_dout[23:16], sd_burst_dout[31:24],
                          sd_burst_dout[39:32], sd_burst_dout[47:40], sd_burst_dout[55:48], sd_burst_dout[63:56]};

    // start of the sprite rows of version v inside bank 1
    function [20:0] vbase(input [1:0] v);
        vbase = 21'h000000;                      // the sprite ROM is the same in every version of this game: one copy
    endfunction

    localparam S_IDLE = 0, S_HOLD = 1, S_WAIT_W = 2, S_WAIT_R = 3, S_GAP = 4;
    reg [2:0]  st = S_IDLE;
    reg [1:0]  gap = 2'd0;
    reg [1:0]  rd_kind;                          // which target the running read fills: 0 tile cache, 1 sprite cache, 2 staging read
    reg [15:0] rd_tag;
    reg [1:0]  rd_ver;

    always @(posedge clk) begin
        gw_ack <= 1'b0;
        rr_ack <= 1'b0;
        if (rst && !gw_valid) begin
            // the video block is held in reset while the ROMs download or a version is copied; keep the caches empty so no stale row is served afterwards
            tvalid <= 1'b0; svalid <= 1'b0;
        end
        case (st)
            S_IDLE: if (sd_ready) begin
                if (gw_valid) begin
                    case (gw_kind)
                        2'd0:    sd_addr <= {2'b00, 4'b0, gw_off[18:0]};
                        2'd1:    sd_addr <= {2'b01, 2'b0, {2'b00, gw_off[18:0]} + vbase(gw_ver)};
                        default: sd_addr <= {2'b10, 2'b0, gw_off};
                    endcase
                    sd_din  <= {gw_data, gw_data};
                    sd_we   <= 1'b1; gw_ack <= 1'b1;
                    tvalid  <= 1'b0; svalid <= 1'b0;                 // the ROM contents are changing
                    st <= S_HOLD;
                end else if (rr_req && !rr_ack) begin
                    sd_addr <= {2'b10, 2'b0, rr_addr[20:3], 3'b000};
                    rd_kind <= 2'd2;
                    sd_rdburst <= 1'b1; st <= S_HOLD;
                end else if (!rst && !tile_ok) begin
                    sd_addr <= {2'b00, 4'b0, tile_row_addr, 3'b000};
                    rd_kind <= 2'd0; rd_tag <= tile_row_addr;
                    sd_rdburst <= 1'b1; st <= S_HOLD;
                end else if (!rst && !spr_ok) begin
                    sd_addr <= {2'b01, 2'b0, {2'b00, spr_row_addr, 3'b000} + vbase(spr_ver)};
                    rd_kind <= 2'd1; rd_tag <= spr_row_addr; rd_ver <= spr_ver;
                    sd_rdburst <= 1'b1; st <= S_HOLD;
                end
            end
            // sdram.sv reacts to the rising edge of we / rdburst one clock later and only then drops ready: hold the request for two clocks
            S_HOLD: begin
                st <= sd_we ? S_WAIT_W : S_WAIT_R;
                sd_we <= 1'b0; sd_rdburst <= 1'b0;
            end
            // sdram.sv loses a write that follows the previous one immediately when a refresh falls in between (found with the Micron model,
            // sim_sdram/); the GX7 tests that proved the controller always left three clocks between writes, so do the same
            S_WAIT_W: if (sd_ready) begin gap <= 2'd2; st <= S_GAP; end
            S_GAP: begin gap <= gap - 1'd1; if (gap == 0) st <= S_IDLE; end
            S_WAIT_R: if (sd_burst_ready) begin
                if (rd_kind == 2'd1)      begin sq <= row_in; stag <= rd_tag; sver <= rd_ver; svalid <= 1'b1; end
                else if (rd_kind == 2'd0) begin tq <= row_in; ttag <= rd_tag; tvalid <= 1'b1; end
                else begin
                    rr_q <= {sd_burst_dout[63:56], sd_burst_dout[55:48], sd_burst_dout[47:40], sd_burst_dout[39:32],
                             sd_burst_dout[31:24], sd_burst_dout[23:16], sd_burst_dout[15:8],  sd_burst_dout[7:0]};   // byte i = bits 8i+7:8i
                    rr_ack <= 1'b1;
                end
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
    end

    initial begin sd_addr = 25'd0; sd_din = 16'd0; sd_we = 1'b0; sd_rdburst = 1'b0; gw_ack = 1'b0; rr_ack = 1'b0; rr_q = 64'd0; rd_kind = 2'd0; rd_tag = 16'd0; rd_ver = 2'd0; end
endmodule
