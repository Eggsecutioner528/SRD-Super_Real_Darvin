# ---------------------------------------------------------------------------------------------------------------------
# Super Real Darwin for MiSTer - Copyright (C) 2026 Eggsecutioner528
# Licensed under the GNU General Public License, version 2 or (at your option) any later version (see LICENSE).
# Any copy or derived work must keep this notice, name the author and be published with its complete source under the same license.
# Provenance mark GDM-f19f84058d24
# ---------------------------------------------------------------------------------------------------------------------
"""The ROM sets of SRD (World = MAME srdarwin, Japan = srdarwinj) and the combined download stream that rtl/srd_loader.v expects.
Used by make_mra.py (one MRA per version) and check_mra.py. The Japanese set only replaces the main CPU ROM dy_01 and the MCU ROM, everything else comes
from srdarwin.zip.

Stream layout (see rtl/srd_loader.v): 0x00000 tile ROM (four banks of dy_03 chunk, dy_02 chunk, 0x4000 bytes each), 0x20000 sprite ROM (six files of 0x8000),
then the block of the one version this MRA carries (each MRA holds one version) at 0x50000: dy_00 (0x10000), dy_01 (0x10000), character ROM (0x4000), MCU ROM (0x1000), sound ROM (0x8000)."""
import os, zipfile

ZDIR = os.environ.get("SRD_ZIPS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "roms"))
VERSIONS = ["World", "Japan"]          # order = value of the OSD option Game Version
BLOCK = 0x2D000
V0 = 0x50000

# logical file -> (zip, name, crc)
WORLD = {
    "dy00": ("srdarwin.zip", "dy_00.b16", "2bf6b461"), "dy01": ("srdarwin.zip", "dy_01-e.b14", "176e9299"),
    "char": ("srdarwin.zip", "dy_05.b6", "8780e8a3"), "mcu": ("srdarwin.zip", "dy-e.d11", "11cd6ca4"), "snd": ("srdarwin.zip", "dy_04.d7", "2ae3591c"),
    "tlo": ("srdarwin.zip", "dy_03.b4", "44f2a4f9"), "thi": ("srdarwin.zip", "dy_02.b5", "522d9a9e"),
    "s0": ("srdarwin.zip", "dy_07.h16", "97eaba60"), "s1": ("srdarwin.zip", "dy_06.h14", "c279541b"), "s2": ("srdarwin.zip", "dy_09.k13", "d30d1745"),
    "s3": ("srdarwin.zip", "dy_08.k11", "71d645fd"), "s4": ("srdarwin.zip", "dy_11.k16", "fd9ccc5b"), "s5": ("srdarwin.zip", "dy_10.k14", "88770ab8"),
}
JAPAN = dict(WORLD)
JAPAN.update({"dy01": ("srdarwinj.zip", "dy_01.b14", "1eeee4ff"), "mcu": ("srdarwinj.zip", "dy.d11", "4ac2ca9d")})
SETS = [WORLD, JAPAN]
ZIPS = "srdarwin.zip|srdarwinj.zip"
SPRITES = ("s0", "s1", "s2", "s3", "s4", "s5")

# the same files under the older split-set names (Japan: dy_01.rom, id8751h_japan.mcu), used when a name is missing from a zip
ALT = {"dy_01.b14": "dy_01.rom", "dy.d11": "id8751h_japan.mcu"}

def read(entry):
    z, n, c = entry
    zf = zipfile.ZipFile(os.path.join(ZDIR, z))
    names = zf.namelist()
    return zf.read(n if n in names else ALT[n])

def stream(version=0):
    """The download stream of one version (0 = World, 1 = Japan): tiles, sprites, then that version's block at 0x50000."""
    out = bytearray()
    lo, hi = read(WORLD["tlo"]), read(WORLD["thi"])
    for k in range(4):
        out += lo[k * 0x4000:(k + 1) * 0x4000] + hi[k * 0x4000:(k + 1) * 0x4000]
    for sp in SPRITES: out += read(WORLD[sp])
    assert len(out) == V0, hex(len(out))
    f = SETS[version]
    out += read(f["dy00"]) + read(f["dy01"]) + read(f["char"]) + read(f["mcu"]) + read(f["snd"])
    return bytes(out)
