// ---------------------------------------------------------------------------------------------------------------------
// Super Real Darwin for MiSTer - Copyright (C) 2026 Eggsecutioner528
// Licensed under the GNU General Public License, version 2 or (at your option) any later version (see LICENSE).
// Any copy or derived work must keep this notice, name the author and be published with its complete source under the same license.
// Provenance mark GDM-066d991d9e10
// ---------------------------------------------------------------------------------------------------------------------
// Super Real Darwin main board: 6809E, program ROM, RAMs, video block, vblank NMI and the i8751 mailbox glue.
// Everything runs from one 48 MHz clock; the CPU is clocked E and Q at 2 MHz from an 8 MHz enable (4 phases of 6 clocks).
// Written from MAME's dec8.cpp (srdarwin_state), see docs/PROJECT_NOTES.md.
//
// Memory map: 0000-05FF RAM, 0600-07FF sprite RAM (copied to the draw buffer by a write to 1804), 0800-0FFF character RAM, 1000-13FF RAM,
// 1400-17FF background RAM (512 tiles x 2 bytes), 1800/1801 MCU value (high/low), 1802-1803 no effect, 1804 sprite copy, 1805 bank and scroll MSB, 1806 scroll LSB,
// 2000 r MCU reply high / w sound command, 2001 r MCU reply low / w flip screen, 2800-288F and 3000-308F palette (low byte, extension byte), 3800-3803 inputs,
// 4000-7FFF ROM bank (3 bit bank number), 8000-FFFF ROM.
`ifndef INT1_W
`define INT1_W 12'd96                      // MCU INT1 pulse: MAME clears it 64 MCU clocks (8 us) after the write to 1800
`endif
module srd_main (
    input             clk,                 // 48 MHz
    input             rst,
    input      [8:0]  init_h, init_v,  // raster position at reset release

    // program ROM download: 0x00000-0x1FFFF = the 8 banks of 16 KB, 0x20000-0x27FFF = the fixed ROM at 8000-FFFF
    input             mrom_we,
    input      [17:0] mrom_wa,
    input      [7:0]  mrom_wd,
    // character ROM download (16 KB)
    input             crom_we,
    input      [13:0] crom_wa,
    input      [7:0]  crom_wd,

    // graphics ROM rows in SDRAM (layout made by tools/make_roms_srd.py)
    output     [15:0] tile_row_addr,
    input      [63:0] tile_row_q,
    input             tile_ok,
    output     [15:0] spr_row_addr,
    input      [63:0] spr_row_q,
    input             spr_ok,

    // inputs as the CPU reads them (1 = released); in1 bit 6 is replaced by the vblank flag
    input      [7:0]  dsw0, in0, in1, dsw1,
    input      [7:0]  coin_p3,         // i8751 port 3: bit 4 service, bit 5 coin 1, bit 6 coin 2, bit 7 coin 3 (active low, low nibble unused = 1)

    // i8751 MCU (jtframe_8751mcu on the FPGA, a C++ model in the Verilator test bench)
    input      [7:0]  mcu_p0_o, mcu_p1_o, mcu_p2_o, mcu_p3_o,
    output     [7:0]  mcu_p0_i, mcu_p1_i, mcu_p2_i, mcu_p3_i,
    output            mcu_int0n, mcu_int1n,

    // sound command (2000)
    output reg [7:0]  snd_cmd = 8'd0,
    output reg        snd_cmd_tog = 1'b0,

    // sync pulse positions (see srd_video)
    input      [8:0]  hs_start, hs_end, vs_start, vs_end,

    // video, registered, raw unrotated raster
    output            pxl_cen,
    output     [7:0]  r, g, b,
    output            hs, vs, hblank, vblank, de,
    output            vbl_start,
    output            vbl_cpu,
    output            flip_screen          // 2001 write (cocktail flip)
);
    // ------------------------------------------------------------------ clocks
    // The CPU is clocked by E and Q, so it can only notice a reset while E and Q are running: the dividers keep running during the first 255 clocks of a reset and
    // are then held (same arrangement as the Gondomania core).
    reg [7:0] rst_age = 8'd0;
    always @(posedge clk) rst_age <= rst ? ((rst_age == 8'hFF) ? rst_age : rst_age + 1'd1) : 8'd0;
    wire rst_hold = rst && (rst_age == 8'hFF);
    reg [2:0] div = 3'd0;                              // 48 MHz -> 8 MHz enable
    always @(posedge clk) div <= rst_hold ? 3'd0 : (div == 3'd5) ? 3'd0 : div + 1'd1;
    wire cen8 = (div == 3'd5);
    reg [1:0] cdiv = 2'd0;                             // 8 MHz -> 2 MHz E and Q
    always @(posedge clk) if (rst_hold) cdiv <= 2'd0; else if (cen8) cdiv <= cdiv + 1'd1;
    wire cpu_q = (cdiv == 2'b01 || cdiv == 2'b10);
    wire cpu_e = (cdiv == 2'b10 || cdiv == 2'b11);
    wire e_end = cen8 && cdiv == 2'b11;                // last clock of a bus cycle: the cycle that ends here is the one to act on

    reg [2:0] pdiv = 3'd0;                             // 48 MHz -> 6 MHz pixel clock enable
    always @(posedge clk) pdiv <= rst ? 3'd0 : pdiv + 1'd1;
    assign pxl_cen = (pdiv == 3'd7);

    // ------------------------------------------------------------------ CPU
    wire [7:0]  cpu_dout;
    wire [15:0] cpu_addr;
    wire        cpu_rw;
    reg  [7:0]  cpu_din;
    reg         nmi_n = 1'b1;
    reg         irq = 1'b0;
    wire        cpu_lic;

    hd6309i cpu (
        .D(cpu_din), .DOut(cpu_dout), .ADDR(cpu_addr), .RnW(cpu_rw),
        .E(cpu_e), .Q(cpu_q), .BS(), .BA(),
        .nIRQ(~irq), .nFIRQ(1'b1), .nNMI(nmi_n),
        .AVMA(), .BUSY(), .LIC(cpu_lic),
        .nRESET(~rst), .nDMABREQ(1'b1), .nHALT(1'b1)
    );

    // ------------------------------------------------------------------ address decode
    wire wr_cyc   = e_end && !cpu_rw;                  // a write cycle just ended
    wire a_ram0   = cpu_addr < 16'h0600;
    wire a_spr    = cpu_addr[15:9] == 7'b0000011;      // 0600-07FF
    wire a_chr    = cpu_addr[15:11] == 5'b00001;       // 0800-0FFF
    wire a_ram1   = cpu_addr[15:10] == 6'b000100;      // 1000-13FF
    wire a_bg     = cpu_addr[15:10] == 6'b000101;      // 1400-17FF
    wire a_pal    = cpu_addr >= 16'h2800 && cpu_addr < 16'h2890;
    wire a_pale   = cpu_addr >= 16'h3000 && cpu_addr < 16'h3090;
    wire a_rombk  = cpu_addr[15:14] == 2'b01;
    wire a_romfx  = cpu_addr[15];

    // ------------------------------------------------------------------ registers written by the CPU
    reg [7:0] ctrl = 8'h00;                            // 1805: bits 7-5 ROM bank, bits 3-0 scroll MSB
    reg [7:0] scr_lo = 8'h00;                          // 1806
    reg [7:0] value_hi = 0, value_lo = 0, ret_hi = 0, ret_lo = 0;
    reg       int1_tog = 0, int1_tog_d = 0, flip = 1'b0;
    reg [11:0] int1_cnt = 0;
    reg [7:0] p2_d = 8'hff;
    assign flip_screen = flip;

    // ------------------------------------------------------------------ RAMs
    reg [7:0] wram [0:2559];                           // 0000-05FF and 1000-13FF
    reg [7:0] wram_q;
    wire [11:0] wram_a = a_ram0 ? {1'b0, cpu_addr[10:0]} : (12'd1536 + {2'b0, cpu_addr[9:0]});
    always @(posedge clk) begin
        if (wr_cyc && (a_ram0 || a_ram1)) wram[wram_a] <= cpu_dout;
        wram_q <= wram[wram_a];
    end

    // character RAM (2 KB), CPU port and video port
    wire [10:0] fix_addr; wire [7:0] fix_q, chr_cq;
    srd_dpram #(11) u_chr (.clk(clk), .we(wr_cyc && a_chr), .wa(cpu_addr[10:0]), .wd(cpu_dout), .ra1(cpu_addr[10:0]), .rq1(chr_cq), .ra2(fix_addr), .rq2(fix_q));
    // background RAM (512 words), kept as a high and a low byte RAM so the video block reads a word
    wire [8:0] bg_addr; wire [15:0] bg_q; wire [7:0] bgh_cq, bgl_cq;
    srd_dpram #(9) u_bgh (.clk(clk), .we(wr_cyc && a_bg && !cpu_addr[0]), .wa(cpu_addr[9:1]), .wd(cpu_dout), .ra1(cpu_addr[9:1]), .rq1(bgh_cq), .ra2(bg_addr), .rq2(bg_q[15:8]));
    srd_dpram #(9) u_bgl (.clk(clk), .we(wr_cyc && a_bg &&  cpu_addr[0]), .wa(cpu_addr[9:1]), .wd(cpu_dout), .ra1(cpu_addr[9:1]), .rq1(bgl_cq), .ra2(bg_addr), .rq2(bg_q[7:0]));
    // palette, 144 entries: low byte at 2800, extension byte at 3000
    wire [7:0] pal_addr; wire [15:0] pal_q; wire [7:0] pall_cq, pale_cq;
    srd_dpram #(8) u_pall (.clk(clk), .we(wr_cyc && a_pal),  .wa(cpu_addr[7:0]), .wd(cpu_dout), .ra1(cpu_addr[7:0]), .rq1(pall_cq), .ra2(pal_addr), .rq2(pal_q[7:0]));
    srd_dpram #(8) u_pale (.clk(clk), .we(wr_cyc && a_pale), .wa(cpu_addr[7:0]), .wd(cpu_dout), .ra1(cpu_addr[7:0]), .rq1(pale_cq), .ra2(pal_addr), .rq2(pal_q[15:8]));

    // sprite RAM (512 bytes) and the draw buffer a write to 1804 copies it into
    wire [8:0] spr_addr; wire [7:0] spr_q, spr_cq;
    reg        cp_run = 0;
    reg [9:0]  cp_cnt = 0;
    wire [8:0] cp_ra = cp_cnt[8:0];
    wire [7:0] cp_d, unused_b;
    wire       cp_wv = cp_run && cp_cnt != 0;          // the RAM read data is one clock late: at count c it holds address c-1
    wire [8:0] cp_wa = cp_cnt[8:0] - 1'd1;
    srd_dpram #(9) u_spr (.clk(clk), .we(wr_cyc && a_spr), .wa(cpu_addr[8:0]), .wd(cpu_dout), .ra1(cpu_addr[8:0]), .rq1(spr_cq), .ra2(cp_ra), .rq2(cp_d));
    srd_dpram #(9) u_buf (.clk(clk), .we(cp_wv), .wa(cp_wa), .wd(cp_d), .ra1(9'd0), .rq1(unused_b), .ra2(spr_addr), .rq2(spr_q));
    always @(posedge clk) begin
        if (cp_run) begin
            cp_cnt <= cp_cnt + 1'd1;
            if (cp_cnt == 10'd512) cp_run <= 1'b0;
        end
        if (rst) begin cp_run <= 1'b0; cp_cnt <= 0; end
        else if (wr_cyc && cpu_addr == 16'h1804) begin cp_run <= 1'b1; cp_cnt <= 0; end
    end

    // program ROM: 8 banks of 16 KB, then the fixed 32 KB
    reg [7:0] rom [0:163839];
    reg [7:0] rom_q;
    wire [17:0] rom_ra = a_romfx ? {3'b100, cpu_addr[14:0]} : {1'b0, ctrl[7:5], cpu_addr[13:0]};   // 0x20000 + offset, or bank * 16 KB + offset
    always @(posedge clk) begin
        if (mrom_we) rom[mrom_wa] <= mrom_wd;
        rom_q <= rom[rom_ra];
    end

    // character ROM (16 KB), read by the video block one byte at a time
    reg [7:0] cr [0:16383];
    wire [13:0] char_row_addr;
    reg  [7:0] char_row_q;
    always @(posedge clk) begin
        if (crom_we) cr[crom_wa] <= crom_wd;
        char_row_q <= cr[char_row_addr];
    end

    // ------------------------------------------------------------------ reads
    wire vbl_cpu_w;
    always @(*) begin
        if (a_romfx || a_rombk)                   cpu_din = rom_q;
        else if (a_ram0 || a_ram1)                cpu_din = wram_q;
        else if (a_spr)                           cpu_din = spr_cq;
        else if (a_chr)                           cpu_din = chr_cq;
        else if (a_bg)                            cpu_din = cpu_addr[0] ? bgl_cq : bgh_cq;
        else if (a_pal)                           cpu_din = pall_cq;
        else if (a_pale)                          cpu_din = pale_cq;
        else case (cpu_addr)
            16'h2000: cpu_din = ret_hi;                     // i8751 reply, high byte
            16'h2001: cpu_din = ret_lo;                     // i8751 reply, low byte
            16'h3800: cpu_din = dsw0;
            16'h3801: cpu_din = in0;
            16'h3802: cpu_din = {in1[7], vbl_cpu_w, in1[5:0]};   // bit 6 = vblank (high during vblank)
            16'h3803: cpu_din = dsw1;
            default:  cpu_din = 8'hff;
        endcase
    end

    // ------------------------------------------------------------------ NMI: the vblank level straight into the CPU (no enable on this board)
    always @(posedge clk) if (cen8) nmi_n <= ~vbl_cpu_w;
    assign vbl_cpu = vbl_cpu_w;

    // ------------------------------------------------------------------ i8751 mailbox glue
    // The main CPU writes a 16 bit value (1800 high, 1801 low); the write to 1800 pulses MCU INT1. The MCU reads the two bytes on port 0 through buffers enabled by P2.4 (high)
    // and P2.5 (low) and answers by writing port 0 and dropping P2.6 (reply high, read at 2000) and P2.7 (reply low, 2001). P2.2 low raises the main CPU IRQ; MAME never
    // clears it again (the game's IRQ vector is a bare RTI).
    always @(posedge clk) if (cen8) begin
        int1_tog_d <= int1_tog;
        if (int1_tog != int1_tog_d) int1_cnt <= `INT1_W;
        else if (int1_cnt != 0) int1_cnt <= int1_cnt - 1'd1;
        p2_d <= mcu_p2_o;
        if (p2_d[6] & ~mcu_p2_o[6]) ret_hi <= mcu_p0_o;
        if (p2_d[7] & ~mcu_p2_o[7]) ret_lo <= mcu_p0_o;
        if (~mcu_p2_o[2]) irq <= 1'b1;
        if (rst) irq <= 1'b0;
    end
    assign mcu_p0_i  = (mcu_p2_o[4] ? 8'hff : value_hi) & (mcu_p2_o[5] ? 8'hff : value_lo);
    assign mcu_p1_i  = 8'hff;
    assign mcu_p2_i  = 8'hff;
    assign mcu_p3_i  = coin_p3;                                  // coin and service inputs
    assign mcu_int1n = (int1_cnt == 0);
    assign mcu_int0n = 1'b1;                                     // not used on this board

    // ------------------------------------------------------------------ CPU writes to the registers
    always @(posedge clk) begin
        if (rst) begin
            ctrl <= 8'h00; scr_lo <= 8'h00; flip <= 1'b0;
        end else if (e_end && !cpu_rw) begin
            case (cpu_addr)
                16'h1800: begin value_hi <= cpu_dout; int1_tog <= ~int1_tog; end
                16'h1801: value_lo <= cpu_dout;
                16'h1805: ctrl <= cpu_dout;
                16'h1806: scr_lo <= cpu_dout;
                16'h2000: begin snd_cmd <= cpu_dout; snd_cmd_tog <= ~snd_cmd_tog; end
                16'h2001: flip <= cpu_dout[0];
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------ video
    srd_video u_video (
        .clk(clk), .rst(rst), .pxl_cen(pxl_cen), .init_h(init_h), .init_v(init_v),
        .scrx({ctrl[3:0], scr_lo}), .flip(flip),
        .hs_start(hs_start), .hs_end(hs_end), .vs_start(vs_start), .vs_end(vs_end),
        .fix_addr(fix_addr), .fix_q(fix_q), .bg_addr(bg_addr), .bg_q(bg_q), .spr_addr(spr_addr), .spr_q(spr_q),
        .pal_addr(pal_addr), .pal_q(pal_q),
        .char_row_addr(char_row_addr), .char_row_q(char_row_q),
        .tile_row_addr(tile_row_addr), .tile_row_q(tile_row_q), .tile_ok(tile_ok),
        .spr_row_addr(spr_row_addr), .spr_row_q(spr_row_q), .spr_ok(spr_ok),
        .r(r), .g(g), .b(b), .hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank), .de(de), .vbl_start(vbl_start), .vbl_cpu(vbl_cpu_w)
    );
endmodule

// Simple dual port RAM: port 1 is written and read (for the CPU), port 2 is read only (for the video block); both reads are registered.
module srd_dpram #(parameter AW = 10) (
    input             clk,
    input             we,
    input  [AW-1:0]   wa,
    input  [7:0]      wd,
    input  [AW-1:0]   ra1,
    output reg [7:0]  rq1,
    input  [AW-1:0]   ra2,
    output reg [7:0]  rq2
);
    reg [7:0] mem [0:(1 << AW) - 1];
    always @(posedge clk) begin
        if (we) mem[wa] <= wd;
        rq1 <= mem[ra1];
        rq2 <= mem[ra2];
    end
endmodule
