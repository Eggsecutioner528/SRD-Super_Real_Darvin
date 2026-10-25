# Super Real Darwin (SRD) for MiSTer: authorship and notices

Super Real Darwin (Data East DECO8 hardware, 1987) for the MiSTer FPGA platform. Copyright (C) 2026 Eggsecutioner528.
This project's own files carry a copyright and license header . They are licensed under the
GNU General Public License, version 2 or (at your option) any later version (see `LICENSE`). Anyone who copies, adapts or ships any of
them must keep the notice, name the author and publish the complete source of the resulting work under the same license.

## What is original work in this repository
The main board (`rtl/srd_main.v`), the video block (`rtl/video/srd_video.v`), the ROM loader, the SDRAM ROM module and the game
version copy engine (`rtl/srd_loader.v`, `rtl/srd_gfxrom.v`, `rtl/srd_vsel.v`), the sound board glue and mixer
(`rtl/srd_sound.v`, `rtl/audio_lp.v`), the DDR3 rotation hub (`rtl/ddr_rotate_hub.sv`), the top level additions
in `SRD.sv`, the MRA and its generator, the simulation test benches and all of `tools/`. They were written from MAME's driver
behavior, the Data East service and technical support manuals, datasheets and the author's own tests. No bitstream of any other core was used.

## Third-party components (kept under their own licenses and notices)
* `rtl/jt65c02`, `rtl/jt12` (JT03/JT12), `rtl/jtopl`, `rtl/jt49`, `rtl/jt8051/jtframe_*`: by Jose Tejada (jotego), part of the JTCORES project, GNU GPL version 3.
* `rtl/jt8051/mc8051.v`: a Verilog translation of Oregano Systems' 8051 core (see `rtl/jt8051/LICENSE`), used through Jose Tejada's `jtframe_8751mcu`.
* `rtl/hd6309/hd6309i.v`: Roger Taylor's Hitachi 6309 version of Greg Miller's MC6809 core (see the file's header).
* `sys/` and the starting point of `SRD.sv`, `rtl/sdram.sv`, `rtl/screen_rotate_ex.v`: the MiSTer framework by Sorgelig and the MiSTer contributors, GNU GPL. Changes made here are marked in each file.
* `sim_sdram/mt48lc16m16a2.v`: Micron's SDRAM behavioral model, used only in simulation.
* `rtl/jt12` and `rtl/jtopl` are, as their headers state, based on information posted by Nemesis and on Sauraen's VHDL version of OPN/OPN2 (itself based on die shots).
* The behavior of the original hardware was studied through MAME (the MAME team).

## How to check a suspect file
`python tools/verify_fingerprint.py <file or folder>` (needs the author's private salt file).

<!-- Super Real Darwin for MiSTer - Copyright (C) 2026 Eggsecutioner528  Licensed under the GNU General Public License, version 2 or (at your option) any later version (see LICENSE).  Any copy or derived work must keep this notice, name the author and be published with its complete source under the same license.  Provenance mark GDM-1b798931fcde -->
