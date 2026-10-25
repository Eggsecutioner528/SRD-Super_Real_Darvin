// ---------------------------------------------------------------------------------------------------------------------
// Super Real Darwin for MiSTer - Copyright (C) 2026 Eggsecutioner528
// Licensed under the GNU General Public License, version 2 or (at your option) any later version (see LICENSE).
// Any copy or derived work must keep this notice, name the author and be published with its complete source under the same license.
// Provenance mark GDM-d096328bade0
// ---------------------------------------------------------------------------------------------------------------------
// Super Real Darwin video: timing generator, line renderer (scrolling background, sprites, character layer) and RM-C3 palette.
// Written from MAME's dec8_v.cpp (srdarwin_state), see docs/PROJECT_NOTES.md.
//
// Raster (6 MHz pixel clock, from the 12 MHz crystal, same as Gondomania): 384 x 272, active 256 columns x lines 8..247, 57.44 Hz.
// The picture is the raw, unrotated raster of the vertical monitor (the game is ROT270); rotation for a CRT is done downstream.
//
// Structure: line N+1 is rendered into one line buffer while line N is output from the other. All memories are synchronous with one clock of
// read latency (address register loaded at edge E0, data register loaded at E1, usable at E2). The module runs from clk with a pixel clock
// enable every 8 clocks: the renderer has 8 x 384 = 3072 clocks per line.
// Line buffer entry = {lay0, palette index[7:0]}: lay0 = the pixel belongs to background "layer 0" (in front of sprites of colour 0).
// Palette: 0-127 background (colour * 16 + pen), 64-127 overlap rule: sprites use 64 + colour * 8 + pen, characters 128 + pen (as MAME's gfxdecode bases).
// Graphics ROM rows: 16 pens of 4 bits (pen 0 in bits 63:60) per row; tiles {tile[9:0], row}, sprites {code[10:0], row}.
`ifndef SPR_DESC
`define SPR_FIRST 7'd0
`define SPR_LAST 7'd127
`define SPR_NEXT (si + 1'd1)
`else
`define SPR_FIRST 7'd127
`define SPR_LAST 7'd0
`define SPR_NEXT (si - 1'd1)
`endif
module srd_video (
    input             clk,
    input             rst,
    input      [8:0]  init_h, init_v,   // raster position at reset release (calibrated against MAME: it sets where the first NMI lands)
    input             pxl_cen,          // one clk wide, once per pixel (6 MHz)

    // CPU written video registers
    input      [11:0] scrx,             // background scroll X (1805 low nibble, 1806)
    input             flip,             // 2001 bit 0 (not applied yet: cocktail only)
    // sync pulse positions (the CRT position options move them; the picture itself does not move): hs on [hs_start, hs_end), vs on [vs_start, vs_end)
    input      [8:0]  hs_start, hs_end, vs_start, vs_end,

    // memories (read ports)
    output reg [10:0] fix_addr,  input [7:0]  fix_q,      // character RAM, 2048 bytes (0800-0FFF)
    output reg [8:0]  bg_addr,   input [15:0] bg_q,       // background RAM, 512 words (1400-17FF)
    output reg [8:0]  spr_addr,  input [7:0]  spr_q,      // sprite buffer, 512 bytes
    output reg [7:0]  pal_addr,  input [15:0] pal_q,      // palette, 144 entries {ext, low}
    output reg [13:0] char_row_addr, input [7:0] char_row_q,    // character ROM bytes
    output reg [15:0] tile_row_addr, input [63:0] tile_row_q, input tile_ok,   // background tile ROM rows {tile, row} (ok = q holds the row of the current address)
    output reg [15:0] spr_row_addr,  input [63:0] spr_row_q,  input spr_ok,     // sprite ROM rows {code, row}

    // video out (registered, one pixel after the counters)
    output reg [7:0]  r, g, b,
    output reg        hs, vs, hblank, vblank, de,
    output            vbl_start,            // pulses once per frame when vblank starts (line 248)
    output            vbl_cpu               // vblank as the main CPU sees it (NMI source, bit 6 of 3802): high on lines 248..271 and 0..7
);
    initial begin
        fix_addr = 0; bg_addr = 0; spr_addr = 0; pal_addr = 0; char_row_addr = 0; tile_row_addr = 0; spr_row_addr = 0;
        r = 0; g = 0; b = 0; hs = 0; vs = 0; hblank = 0; vblank = 0; de = 0;
    end

    // ---------------------------------------------------------------- timing
    localparam HTOTAL = 384, VTOTAL = 272, HACT = 256, V0 = 8, V1 = 248;
    reg [8:0] hcnt = 9'd0, vcnt = 9'd0;
    always @(posedge clk) begin
        if (rst) begin hcnt <= init_h; vcnt <= init_v; end
        else if (pxl_cen) begin
            if (hcnt == HTOTAL - 1) begin
                hcnt <= 0;
                vcnt <= (vcnt == VTOTAL - 1) ? 9'd0 : vcnt + 1'd1;
            end else hcnt <= hcnt + 1'd1;
        end
    end
    wire line_start = pxl_cen && hcnt == HTOTAL - 1;       // the edge at which a new line begins
    assign vbl_start = line_start && vcnt == V1 - 1;
    assign vbl_cpu   = !(vcnt >= V0 && vcnt < V1);

    // ---------------------------------------------------------------- line buffers {lay0, palette index[7:0]}
    reg [8:0] lb0 [0:255];
    reg [8:0] lb1 [0:255];
    reg       rsel = 0;                                     // 0: lb0 is displayed and lb1 rendered, 1: the other way round
    always @(posedge clk) if (line_start) rsel <= ~rsel;
    reg        lbw_we;
    reg [7:0]  lbw_x;
    reg [8:0]  lbw_d;
    always @(posedge clk) if (lbw_we) begin
        if (rsel) lb0[lbw_x] <= lbw_d; else lb1[lbw_x] <= lbw_d;
    end
    reg [8:0] lbr_q;                                        // display side read
    always @(posedge clk) lbr_q <= rsel ? lb1[hcnt[7:0]] : lb0[hcnt[7:0]];
    reg [7:0] wrd_x;                                        // render side read (sprite priority test)
    reg [8:0] wrd_q;
    always @(posedge clk) wrd_q <= rsel ? lb0[wrd_x] : lb1[wrd_x];

    // ---------------------------------------------------------------- line renderer
    wire [8:0] target = (vcnt == VTOTAL - 1) ? 9'd0 : vcnt + 1'd1;   // the line to render: the one after the line being output
    wire       target_ok = !target[8];                                // the tilemap space is y 0..255
    wire [7:0] ty = target[7:0];

    localparam S_IDLE = 0, S_DONE = 1,
               S_B0 = 2, S_B1 = 3, S_B2 = 4, S_B3 = 5, S_B4 = 6, S_B5 = 7,
               S_S0 = 8, S_S1 = 9, S_S2 = 10, S_S3 = 11, S_S4 = 12, S_S5 = 13, S_S6 = 14, S_S7 = 15, S_S8 = 16, S_S9 = 17, S_S10 = 18, S_S11 = 19, S_SPIX = 20, S_SNEXT = 21,
               S_C0 = 22, S_C1 = 23, S_C2 = 24, S_C3 = 25, S_C4 = 26, S_C5 = 27, S_C6 = 28, S_C7 = 29;
    reg [4:0]  st = S_IDLE;
    reg [8:0]  lscx;                     // scroll latched at the start of the line

    // --- background
    reg [4:0]  bk;                       // tile counter within the line, 0..16
    wire [4:0] bcol = lscx[8:4] + bk[4:0];   // map tile column (wraps at 32)
    reg [1:0]  bcolor;
    // The ROM rows arrive as the raw ROM bytes of one 16 pixel row (srd_loader / tools/make_roms_srd.py), the pens are picked out here.
    // Tile row word, byte 0 = bits 63:56: lo0 hi0 lo1 hi1 lo2 hi2 lo3 hi3 (group g = pixels 4g..4g+3); pen = hi[7-pb] hi[3-pb] lo[7-pb] lo[3-pb], pb = x & 3.
    function [63:0] tile_pens(input [63:0] w);
        integer x; reg [7:0] lo, hi; integer pb;
        begin
            tile_pens = 64'd0;
            for (x = 0; x < 16; x = x + 1) begin
                lo = w[63 - 16 * (x >> 2) -: 8]; hi = w[55 - 16 * (x >> 2) -: 8]; pb = x & 3;
                tile_pens[63 - 4 * x -: 4] = {hi[7 - pb], hi[3 - pb], lo[7 - pb], lo[3 - pb]};
            end
        end
    endfunction
    // Sprite row word, byte 0 = bits 63:56: p0 left (x 0-7), p0 right, p1 left, p1 right, p2 left, p2 right; pen = p0 p1 p2 (3 bits, MSB first).
    function [63:0] spr_pens(input [63:0] w);
        integer x, h, pb;
        begin
            spr_pens = 64'd0;
            for (x = 0; x < 16; x = x + 1) begin
                h = x >> 3; pb = x & 7;
                spr_pens[63 - 4 * x -: 4] = {1'b0, w[63 - 8 * h - pb], w[47 - 8 * h - pb], w[31 - 8 * h - pb]};
            end
        end
    endfunction
    reg [63:0] bbytes;
    reg [3:0]  bp;                       // pixel within the tile row
    wire [3:0] bpen = bbytes[63 - 4 * bp -: 4];
    wire signed [10:0] bx = $signed({1'b0, bk, 4'b0}) + $signed({7'b0, bp}) - $signed({7'b0, lscx[3:0]});
    wire       blay0 = (bcolor == 2'd3) ? 1'b1 : (bcolor == 2'd0) ? 1'b0 : bpen[3];   // group 0 all layer 1, group 3 all layer 0, groups 1 and 2: pens 8-15 layer 0

    // --- sprites
    reg [6:0]  si;                       // sprite number, 127 down to 0 (sprite 0 ends up on top)
    reg [7:0]  sy, sa1, sxb, scl;
    wire signed [9:0] sd = $signed({2'b0, ty}) - $signed({2'b0, sy});   // line - top of the first sprite
    wire       s_on0 = (sd >= 0) && (sd < 16);
    wire       s_on1 = sa1[4] && (sd >= 16) && (sd < 32);
    wire [10:0] scode = {sa1[7:5], scl};
    wire signed [9:0] sx = 10'sd241 - $signed({2'b0, sxb});
    reg [63:0] sbytes;
    reg [2:0]  scolour;
    reg        sfx;
    reg [4:0]  pc;                       // pixel pipeline counter
    wire [3:0] ppix = sfx ? (4'd15 - pc[3:0]) : pc[3:0];
    wire [3:0] ppen = sbytes[63 - 4 * ppix -: 4];
    wire signed [10:0] pX = $signed({sx[9], sx}) + $signed({6'b0, pc});
    reg        p1_v, p2_v, p1_c0, p2_c0;
    reg [7:0]  p1_x, p2_x, p1_idx, p2_idx;

    // --- characters
    reg [4:0]  tx;
    reg [7:0]  ccode;
    reg [7:0]  cb_hi, cb_lo;             // bytes for pixels 0-3 (second half of the ROM) and 4-7
    reg [2:0]  px;
    wire [1:0] cpen = (px < 3'd4) ? {cb_hi[7 - px[1:0]], cb_hi[3 - px[1:0]]} : {cb_lo[7 - px[1:0]], cb_lo[3 - px[1:0]]};

    always @(posedge clk) begin
        lbw_we <= 1'b0;
        p2_v <= p1_v; p2_x <= p1_x; p2_idx <= p1_idx; p2_c0 <= p1_c0;
        p1_v <= 1'b0;
        if (line_start) begin
            lscx <= scrx[8:0];
            bk <= 0; bp <= 0;
            st <= target_ok ? S_B0 : S_DONE;
        end else case (st)
            // ---- background: 17 tiles of 16 x 16 (the fractional scroll shows part of the first and the last)
            S_B0: begin bg_addr <= {ty[7:4], bcol}; st <= S_B1; end
            S_B1: st <= S_B2;
            S_B2: begin bcolor <= bg_q[13:12]; tile_row_addr <= {bg_q[9:0], ty[3:0]}; st <= S_B3; end
            S_B3: if (tile_ok) st <= S_B4;
            S_B4: begin bbytes <= tile_pens(tile_row_q); bp <= 0; st <= S_B5; end
            S_B5: begin
                if (bx >= 0 && bx < 256) begin lbw_x <= bx[7:0]; lbw_d <= {blay0, 2'b00, bcolor, bpen}; lbw_we <= 1'b1; end
                bp <= bp + 1'd1;
                if (bp == 4'd15) begin
                    if (bk == 5'd16) begin si <= `SPR_FIRST; st <= S_S0; end
                    else begin bk <= bk + 1'd1; st <= S_B0; end
                end
            end
            // ---- sprites: byte 0 (Y) first; only sprites that reach this line are read further
            S_S0: begin spr_addr <= {si, 2'b00}; st <= S_S1; end
            S_S1: st <= S_S2;
            S_S2: begin sy <= spr_q; st <= S_S3; end
            S_S3: begin
                if (sy == 8'hf8 || !(sd >= 0 && sd < 32)) st <= S_SNEXT;
                else begin spr_addr <= {si, 2'b01}; st <= S_S4; end
            end
            S_S4: st <= S_S5;
            S_S5: begin sa1 <= spr_q; spr_addr <= {si, 2'b10}; st <= S_S6; end
            S_S6: st <= S_S7;
            S_S7: begin sxb <= spr_q; spr_addr <= {si, 2'b11}; st <= S_S8; end
            S_S8: st <= S_S9;
            S_S9: begin scl <= spr_q; st <= S_S10; end
            S_S10: begin
                // code 0 means no sprite; the first part covers sd 0..15, the second (code + 1, 16 lines lower) sd 16..31
                if (scode == 11'd0 || !(s_on0 || s_on1)) st <= S_SNEXT;
                else begin
                    spr_row_addr <= {s_on0 ? scode : scode + 1'd1, sd[3:0]};
                    sfx <= sa1[2]; scolour <= {sa1[3], sa1[1:0]};
                    st <= S_S11;
                end
            end
            S_S11: if (spr_ok) begin sbytes <= spr_pens(spr_row_q); pc <= 0; st <= S_SPIX; end
            S_SPIX: begin
                if (pc < 5'd16) begin
                    wrd_x <= pX[7:0];
                    p1_v <= (ppen[2:0] != 3'd0) && pX >= 0 && pX < 256;
                    p1_x <= pX[7:0]; p1_idx <= {2'b01, scolour, ppen[2:0]}; p1_c0 <= (scolour == 3'd0);
                end
                // decide two clocks after the issue, when the line buffer value has arrived: a hidden pixel (colour 0 under layer 0) still marks the priority (MAME)
                if (p2_v) begin
                    lbw_x <= p2_x; lbw_we <= 1'b1;
                    lbw_d <= (p2_c0 && wrd_q[8]) ? {1'b0, wrd_q[7:0]} : {1'b0, p2_idx};
                end
                pc <= pc + 1'd1;
                if (pc == 5'd18) st <= S_SNEXT;
            end
            S_SNEXT: begin
                if (si == `SPR_LAST) begin st <= S_C0; tx <= 0; end
                else begin si <= `SPR_NEXT; st <= S_S0; end
            end
            // ---- character layer: 32 tiles of 8 x 8, pen 0 transparent, on top of everything
            S_C0: begin fix_addr <= {1'b0, ty[7:3], tx}; st <= S_C1; end
            S_C1: st <= S_C2;
            S_C2: begin ccode <= fix_q; char_row_addr <= {1'b1, 2'b00, fix_q, ty[2:0]}; st <= S_C3; end
            S_C3: st <= S_C4;
            S_C4: begin cb_hi <= char_row_q; char_row_addr <= {3'b000, ccode, ty[2:0]}; st <= S_C5; end
            S_C5: st <= S_C6;
            S_C6: begin cb_lo <= char_row_q; px <= 0; st <= S_C7; end
            S_C7: begin
                if (cpen != 2'd0) begin lbw_x <= {tx, px}; lbw_d <= {1'b0, 1'b1, 5'b00000, cpen}; lbw_we <= 1'b1; end
                px <= px + 1'd1;
                if (px == 3'd7) begin
                    if (tx == 5'd31) st <= S_DONE;
                    else begin tx <= tx + 1'd1; st <= S_C0; end
                end
            end
            default: ;
        endcase
    end

    // ---------------------------------------------------------------- output: line buffer -> palette -> RM-C3 weighting
    always @(posedge clk) pal_addr <= lbr_q[7:0];
    function [7:0] comp4(input [3:0] n);        // DECO RM-C3 resistor weights 220, 470, 1k, 2.2k ohm: 0x8f 0x43 0x1f 0x0e
        comp4 = (n[0] ? 8'h0e : 8'h00) + (n[1] ? 8'h1f : 8'h00) + (n[2] ? 8'h43 : 8'h00) + (n[3] ? 8'h8f : 8'h00);
    endfunction
    wire act_h = hcnt < HACT;
    wire act_v = vcnt >= V0 && vcnt < V1;
    always @(posedge clk) if (pxl_cen) begin
        de     <= act_h && act_v;
        hblank <= !act_h;
        vblank <= !act_v;
        hs     <= hcnt >= hs_start && hcnt < hs_end;
        vs     <= (vs_start < vs_end) ? (vcnt >= vs_start && vcnt < vs_end) : (vcnt >= vs_start || vcnt < vs_end);
        if (act_h && act_v) begin
            r <= comp4(pal_q[3:0]); g <= comp4(pal_q[7:4]); b <= comp4(pal_q[11:8]);
        end else begin r <= 8'd0; g <= 8'd0; b <= 8'd0; end
    end
endmodule
