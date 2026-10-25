// ---------------------------------------------------------------------------------------------------------------------
// Additions and changes for the SRD core in this file: Copyright (C) 2026 Eggsecutioner528.
// The original notices of the file stay as they are below; the changes are licensed under the same license as the original.
// Provenance mark GDM-e1074732e630
// ---------------------------------------------------------------------------------------------------------------------
//
// sdram.v
//
// Static RAM controller implementation using SDRAM MT48LC16M16A2
//
// Copyright (c) 2015-2019 Sorgelig
//
// Some parts of SDRAM code used from project:
// http://hamsterworks.co.nz/mediawiki/index.php/Simple_SDRAM_Controller
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. 
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
// ------------------------------------------
//
// v2.1 - Add universal 8/16 bit mode.
//

module sdram
(
   input             init,        // reset to initialize RAM
   input             clk,         // clock ~100MHz
   input             sdram_clk_in, // phase-shifted clk for SDRAM_CLK, from PLL outclk_1 --
                                   // replaces the old internal altddio_out 180deg-shift DDR
                                   // register, which had no SDC timing constraint and could
                                   // route through general fabric with unpredictable added
                                   // delay, eating into the SDRAM read-data setup margin
                                   //
                                  // SDRAM_* - signals to the MT48LC16M16 chip
   inout  reg [15:0] SDRAM_DQ,    // 16 bit bidirectional data bus
   output reg [12:0] SDRAM_A,     // 13 bit multiplexed address bus
   output reg        SDRAM_DQML,  // two byte masks
   output reg        SDRAM_DQMH,  // 
   output reg  [1:0] SDRAM_BA,    // two banks
   output            SDRAM_nCS,   // a single chip select
   output            SDRAM_nWE,   // write enable
   output            SDRAM_nRAS,  // row address select
   output            SDRAM_nCAS,  // columns address select
   output            SDRAM_CKE,   // clock enable
   output            SDRAM_CLK,
                                  //
   input       [1:0] wtbt,        // 16bit mode:  bit1 - write high byte, bit0 - write low byte,
                                  // 8bit mode:  2'b00 - use addr[0] to decide which byte to write
                                  // Ignored while reading.
                                  //
   input      [24:0] addr,        // 25 bit address for 8bit mode. addr[0] = 0 for 16bit mode for correct operations.
   output     [15:0] dout,        // data output to cpu
   input      [15:0] din,         // data input from cpu
   input             we,          // cpu requests write
   input             rd,          // cpu requests read
   output reg        ready,       // dout is valid. Ready to accept new read/write.

   // Burst read extension (added for the K007342/K007420 tile/sprite cache
   // fill bottleneck: both fetch exactly 32 sequential bytes -- 16 words --
   // per cache-line fill today, one BYTE per full ACTIVE->READ->precharge
   // round trip, confirmed as the real throughput bottleneck under Port2/
   // Port3 contention, see project_history/TASKS.md's Task #75/#76
   // "fetch latency, not capacity" conclusion. Purely additive: `addr` is
   // reused as the burst's starting (word-aligned) address, but every
   // existing rd/we/dout/ready path above is completely untouched by this
   // -- a caller that never asserts rdburst sees byte-for-byte identical
   // behavior to before this was added. Uses page-mode reads (row stays
   // open, auto-precharge suppressed until the last word) rather than the
   // SDRAM chip's own native BURST_LENGTH mode register, so the shared
   // MODE register below (BURST_LENGTH=1, "no burst configured") -- and
   // therefore every other caller's timing -- never has to change. Caller
   // must keep the whole burst within one
   // open row (trivially true for a 16-word/32-byte cache-line fetch).
   input             rdburst,     // pulse: start a burst read at `addr`
   input       [3:0] burst_words_m1, // words-1: 0=1 word ... 15=16 words
   output reg [255:0] burst_dout,     // word i lives in bits [16*i +: 16]
   output reg        burst_ready, // pulses once when all words are captured
   // SRD: capture the burst words one clock earlier. On the real board the chip sees the commands one clock earlier than the pad delay assumed
   // in simulation, so every burst arrived as words 1, 2, 3, 3 (found from a wrong title page color pattern); 1 = early capture.
   input             burst_early
);

reg  [2:0] command;                    // (declared before its first use: ModelSim insists, Quartus does not care)
assign SDRAM_CKE  = 1;
assign SDRAM_nCS  = 0;
assign SDRAM_nRAS = command[2];
assign SDRAM_nCAS = command[1];
assign SDRAM_nWE  = command[0];
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];


// no burst configured
localparam BURST_LENGTH        = 3'b000;   // 000=1, 001=2, 010=4, 011=8
localparam ACCESS_TYPE         = 1'b0;     // 0=sequential, 1=interleaved
localparam CAS_LATENCY         = 3'd2;     // 2 for < 100MHz, 3 for >100MHz
localparam OP_MODE             = 2'b00;    // only 00 (standard operation) allowed
localparam NO_WRITE_BURST      = 1'b1;     // 0= write burst enabled, 1=only single access write
localparam MODE                = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};

localparam sdram_startup_cycles= 14'd12100;// 100us, plus a little more, @ 100MHz
localparam cycles_per_refresh  = 14'd375;  // (64ms @ 48MHz)/8192
localparam startup_refresh_max = 14'b11111111111111;

// SDRAM commands
wire [2:0] CMD_NOP             = 3'b111;
wire [2:0] CMD_ACTIVE          = 3'b011;
wire [2:0] CMD_READ            = 3'b101;
wire [2:0] CMD_WRITE           = 3'b100;
wire [2:0] CMD_PRECHARGE       = 3'b010;
wire [2:0] CMD_AUTO_REFRESH    = 3'b001;
wire [2:0] CMD_LOAD_MODE       = 3'b000;

reg [13:0] refresh_count = startup_refresh_max - sdram_startup_cycles;
reg [24:0] save_addr;

reg [15:0] data;
wire sel_byte = rd ? addr[0] : save_addr[0];
assign dout = sel_byte ? {data[15:8], data[7:0]} : {data[7:0], data[15:8]};

typedef enum
{
	STATE_STARTUP,
	STATE_OPEN_1, STATE_OPEN_2,
	STATE_IDLE,	  STATE_IDLE_1, STATE_IDLE_2, STATE_IDLE_3,
	STATE_IDLE_4, STATE_IDLE_5, STATE_IDLE_6, STATE_IDLE_7,
	// Burst read extension: STATE_OPEN_2 branches here instead of issuing
	// a single auto-precharged READ. Issues one READ command per cycle
	// (column address advancing, auto-precharge held off) until the last
	// word's command has gone out, then advances to STATE_IDLE_5 the same
	// cycle -- mirroring how the non-burst read branch above already
	// moves on before its data arrives. See burst_dout/burst_ready
	// capture logic, which runs independent of `state`.
	STATE_BURST_ISSUE
} state_t;

always @(posedge clk) begin
	reg old_we, old_rd, old_rdburst;
	reg [CAS_LATENCY:0] data_ready_delay;

	reg [15:0] new_data;
	reg  [1:0] new_wtbt;
	reg        new_we;
	reg        new_rd;
	reg        new_rdburst;
	reg        save_we = 1;
	reg        save_burst;
	reg  [3:0] save_burst_words_m1;
	reg  [3:0] burst_cmd_idx;
	reg  [3:0] burst_data_idx;
	// Shift register (not "straight math") tracking which of the last
	// CAS_LATENCY cycles issued a burst READ command -- when the oldest
	// slot is set, that command's data is on SDRAM_DQ this cycle. This is
	// the same pattern as data_ready_delay above, generalized to handle a
	// new command going out every cycle instead of just one. Sized
	// [CAS_LATENCY:0] (not [CAS_LATENCY-1:0]) to match data_ready_delay's
	// own width exactly -- the "just issued" marker bit lives at index
	// CAS_LATENCY, needing CAS_LATENCY shifts to reach bit0, giving the
	// same command-to-capture latency data_ready_delay already gets right
	// (verified: sizing this [CAS_LATENCY-1:0] and marking bit
	// CAS_LATENCY-1 instead, an earlier version of this fired capture one
	// cycle too early, silently reading the PREVIOUS word's still-present
	// data on every capture -- caught by a ModelSim testbench,
	// sim_scratch/tb_sdram_burst_read.sv, comparing every captured word
	// against known-preloaded values before this was ever wired into the
	// arbiter or any real design).
	reg [CAS_LATENCY:0] cmd_issued_pipe;

	// See the 2026-09-30 comment below (at the capture logic itself) for why
	// these exist: pairs with the pre-existing `data` register below, which
	// this burst path now shares instead of using its own capture register.
	reg  [3:0] burst_capture_idx;
	reg        burst_capture_valid = 1'b0;

	state_t state = STATE_STARTUP;

	SDRAM_DQ <= 16'bZ;
	command <= CMD_NOP;
	refresh_count  <= refresh_count+1'b1;
	burst_ready <= 1'b0;

	data_ready_delay <= {1'b0, data_ready_delay[CAS_LATENCY:1]};

	if(data_ready_delay[0]) {ready, data}  <= {1'b1, SDRAM_DQ};

	// Burst capture: runs independent of `state` (mirroring how the
	// existing single-read capture above also runs independent of state,
	// since STATE_OPEN_2 already moves on to STATE_IDLE_5 the same cycle
	// it issues the read command, well before the data actually arrives).
	// STATE_BURST_ISSUE below likewise advances to STATE_IDLE_5 the same
	// cycle it issues the LAST burst command -- this block only needs to
	// capture words as they arrive and flag completion, never touch
	// `state` itself (doing so here would race against and lose to
	// whatever the case(state) block below assigns this same cycle).
	//
	// 2026-09-28: split into two stages after TimeQuest found a genuine
	// -4.4ns setup violation on SDRAM_DQ -> burst_dout (Template.sdc's
	// input-delay budget for this pin is razor-thin, +0.6ns margin, tuned
	// against the OLD plain single-word capture register below -- the
	// variable-indexed `burst_dout[16*burst_data_idx +: 16] <= SDRAM_DQ`
	// write puts a 16-way mux/decoder directly in SDRAM_DQ's capture path,
	// eating that thin margin). Stage 1 captures SDRAM_DQ into a plain,
	// mux-free register; stage 2 moves that value into its addressed home
	// in burst_dout one cycle later, where the mux operates on a clean
	// internal signal instead of the tight-timing external pin.
	//
	// 2026-09-30: that first version used a NEW dedicated register
	// (`burst_dq_capture`) for stage 1, reasoning its logic was identical
	// to the proven-good `data <= SDRAM_DQ` capture two lines above. Real
	// hardware (SEED 13 compile) proved that reasoning incomplete: removing
	// the mux fixed burst_dout's timing (confirmed +11.7ns slack), but the
	// NEW register itself still violated (-4.4ns) -- TimeQuest showed
	// Quartus placed it ~3x farther from the SDRAM_DQ pins than `data`
	// (7.1ns vs 2.5ns data delay), evidently pulled toward its consumer
	// (the wide burst_dout mux) rather than its source. `data` and
	// `burst_dq_capture` were logically identical, but the PLACER treated
	// them differently based on their respective fanout. Fix: don't fight
	// the placer with a second register -- reuse `data` itself for burst
	// captures too, inheriting its already-proven-good placement for free.
	// Safe because single-word reads/writes and burst reads are provably
	// mutually exclusive (both funnel through the single new_rd/new_we/
	// new_rdburst dispatcher below into the one shared `state` FSM), so
	// `data` is never written by both capture paths on the same cycle.
	cmd_issued_pipe <= {1'b0, cmd_issued_pipe[CAS_LATENCY:1]};
	burst_capture_valid <= burst_early ? cmd_issued_pipe[1] : cmd_issued_pipe[0];
	if (burst_early ? cmd_issued_pipe[1] : cmd_issued_pipe[0]) begin
		data              <= SDRAM_DQ;
		burst_capture_idx <= burst_data_idx;
		burst_data_idx    <= burst_data_idx + 4'd1;
	end
	if (burst_capture_valid) begin
		burst_dout[16*burst_capture_idx +: 16] <= data;
		if (burst_capture_idx == save_burst_words_m1) begin
			burst_ready <= 1'b1;
			ready       <= 1'b1;
		end
	end

	case(state)
		STATE_STARTUP: begin
			SDRAM_A    <= 0;
			SDRAM_BA   <= 0;

			if (refresh_count == startup_refresh_max-31) begin
				command     <= CMD_PRECHARGE;
				SDRAM_A[10] <= 1;  // all banks
				SDRAM_BA    <= 2'b00;
			end
			if (refresh_count == startup_refresh_max-23) begin
				command     <= CMD_AUTO_REFRESH;
			end
			if (refresh_count == startup_refresh_max-15) begin
				command     <= CMD_AUTO_REFRESH;
			end
			if (refresh_count == startup_refresh_max-7) begin
				command     <= CMD_LOAD_MODE;
				SDRAM_A     <= MODE;
			end

			if(!refresh_count) begin
				state   <= STATE_IDLE;
				ready   <= 1;
				refresh_count <= 0;
			end
		end

		STATE_IDLE_7: state <= STATE_IDLE_6;
		STATE_IDLE_6: state <= STATE_IDLE_5;
		STATE_IDLE_5: state <= STATE_IDLE_4;
		STATE_IDLE_4: state <= STATE_IDLE_3;
		STATE_IDLE_3: state <= STATE_IDLE_2;
		STATE_IDLE_2: state <= STATE_IDLE_1;
		STATE_IDLE_1: begin
			state      <= STATE_IDLE;
			// SRD change: do not raise ready while a new request is already pending. Without this a refresh that falls between two
			// back to back requests ends in this state with the NEXT request queued, ready jumps up, and a caller that waits for ready
			// believes its request finished (it has not even started) and overwrites it. Found with the Micron model (sim_sdram/).
			if(save_we && !new_we && !new_rd && !new_rdburst) ready <= 1;
			// mask possible refresh to reduce colliding.
			if(refresh_count > cycles_per_refresh) begin
				state    <= STATE_IDLE_7;
				command  <= CMD_AUTO_REFRESH;
				refresh_count <= 0;
			end
		end

		STATE_IDLE: begin
			// Priority is to issue a refresh if one is outstanding
			if(refresh_count > (cycles_per_refresh<<1)) state <= STATE_IDLE_1;
			else if(new_rd | new_we | new_rdburst) begin
				new_we      <= 0;
				new_rd      <= 0;
				new_rdburst <= 0;
				save_we     <= new_we;
				save_burst  <= new_rdburst;
				burst_cmd_idx  <= 4'd0;
				burst_data_idx <= 4'd0;
				state    <= STATE_OPEN_1;
				command  <= CMD_ACTIVE;
				SDRAM_A  <= save_addr[22:10];
				SDRAM_BA <= save_addr[24:23];
			end
		end

		STATE_OPEN_1: state <= STATE_OPEN_2;

		STATE_OPEN_2: begin
			if (save_burst) begin
				state <= STATE_BURST_ISSUE;
			end else begin
			SDRAM_A     <= {save_we ? (new_wtbt ? ~new_wtbt[1] : ~save_addr[0]) : 1'b0,
			                save_we ? (new_wtbt ? ~new_wtbt[0] :  save_addr[0]) : 1'b0,
			                1'b1, 1'b0, save_addr[9:1]};
			if(save_we) begin
				command  <= CMD_WRITE;
				SDRAM_DQ <= new_wtbt ? new_data : {new_data[7:0], new_data[7:0]};
				// Was STATE_IDLE_2 (2-cycle cooldown before the next CMD_ACTIVE could be
				// issued) -- confirmed via a controlled FPGA-internal loopback test that
				// rapid back-to-back writes fail while isolated single writes succeed.
				// Auto-precharge (SDRAM_A[10]=1, hardwired for all ops) means the chip's
				// internal precharge doesn't start until tWR after the write completes;
				// the next row activation then needs tRP on top of that. Extended to
				// STATE_IDLE_4 to give the physical chip more margin for tWR+tRP before
				// the next CMD_ACTIVE can be issued.
				//
				// Extended again to STATE_IDLE_5 (2026-08-14, Test 225): IDLE_4 gave
				// enough margin for write-then-ACTIVATE, but a focused ModelSim
				// simulation (sim_scratch/tb_write_refresh_stress.v) found it was NOT
				// quite enough specifically for write-then-AUTO_REFRESH -- a sustained
				// burst of writes under the real ~375-cycle refresh interval (the same
				// pattern the ~640KB boot ROM download produces) hit a reproducible,
				// DETERMINISTIC tRP violation on the Micron behavioral model at the
				// exact same point every run. One additional idle cycle (IDLE_4->
				// IDLE_5) eliminated it completely: 2000 sustained writes, 0 violations,
				// vs. guaranteed failure at IDLE_4. Real hardware likely doesn't halt on
				// a violation like the behavioral model does -- more likely it silently
				// drops or corrupts the write, which would explain why tile ROM data
				// (downloaded LAST in the boot sequence, after ~384KB of prior writes)
				// came back completely zero from SDRAM while earlier-downloaded data
				// (sprites, CPU, audio) was intact.
				state    <= STATE_IDLE_5;
			end
			else begin
				command  <= CMD_READ;
				data_ready_delay[CAS_LATENCY] <= 1;
				// Test 211 tried extending this to STATE_IDLE_7 (+2 cycles),
				// mirroring the write-side fix above, to test whether insufficient
				// row-precharge/activate margin explained k007342's shadow-verify
				// concurrent-access mismatches. Proven NOT the cause: hardware
				// testing showed no improvement, and Test 212's simulation (two
				// independent zero-gap read streams on Port 2 + Port 3
				// simultaneously, real arbiter + sdram.sv + Micron behavioral
				// model) came back 1000/1000 PASS even under WORSE contention than
				// real hardware ever produces -- proving the arbiter/sdram.sv logic
				// itself is sound and the real-hardware failures are most likely a
				// physical/electrical effect outside what RTL timing-margin changes
				// can address. Reverted to the original STATE_IDLE_5 (Test 213).
				state    <= STATE_IDLE_5;
			end
			end
		end

		STATE_BURST_ISSUE: begin
			// Issue one READ command per cycle, column advancing by 1 word
			// each time (page mode -- the row opened in STATE_OPEN_1/2
			// above stays active throughout, since auto-precharge (A10)
			// is held off until the last command). Mirrors STATE_OPEN_2's
			// own read branch above, just parameterized by burst_cmd_idx
			// and without the wtbt/write-side logic, which bursts never
			// use.
			SDRAM_A <= {1'b0, 1'b0,
			            (burst_cmd_idx == save_burst_words_m1), // A10: auto-precharge on the last word only
			            1'b0, save_addr[9:1] + {5'd0, burst_cmd_idx}};
			command <= CMD_READ;
			// Override just the freshly-shifted-in top bit of the capture
			// pipe (set to 0 by the unconditional shift above) to mark
			// "a command was issued this cycle" -- same override-after-
			// shift idiom this file already uses for data_ready_delay in
			// the non-burst read branch above.
			cmd_issued_pipe[CAS_LATENCY] <= 1'b1;
			if (burst_cmd_idx == save_burst_words_m1) begin
				// Last command just went out -- move on immediately, same
				// as the non-burst read branch does (STATE_OPEN_2 advances
				// to STATE_IDLE_5 the same cycle it issues CMD_READ, long
				// before the data itself arrives). The capture logic above
				// keeps running independent of `state` and will flag
				// burst_ready/ready once the last word lands.
				state <= STATE_IDLE_5;
			end else begin
				burst_cmd_idx <= burst_cmd_idx + 4'd1;
			end
		end
	endcase

	if(init) begin
		state <= STATE_STARTUP;
		refresh_count <= startup_refresh_max - sdram_startup_cycles;
	end

	old_we <= we;
	if(we & ~old_we) begin
		save_addr <= addr;
		{ready, new_we, new_data, new_wtbt} <= {1'b0, 1'b1, din, wtbt};
	end

	old_rd <= rd;
	if(rd & ~old_rd) begin
		save_addr <= addr;
		{ready, new_rd} <= {1'b0, 1'b1};
	end

	old_rdburst <= rdburst;
	if(rdburst & ~old_rdburst) begin
		save_addr            <= addr;
		save_burst_words_m1  <= burst_words_m1;
		{ready, new_rdburst} <= {1'b0, 1'b1};
	end
end

// SDRAM_CLK driven directly from the pre-shifted PLL clock (see module port
// comment above) instead of an internally-generated altddio_out DDR shift.
assign SDRAM_CLK = sdram_clk_in;

endmodule
