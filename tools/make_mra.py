# ---------------------------------------------------------------------------------------------------------------------
# Super Real Darwin for MiSTer - Copyright (C) 2026 Eggsecutioner528
# Licensed under the GNU General Public License, version 2 or (at your option) any later version (see LICENSE).
# Any copy or derived work must keep this notice, name the author and be published with its complete source under the same license.
# Provenance mark GDM-b4cae04173fc
# ---------------------------------------------------------------------------------------------------------------------
"""Writes the MRAs of the SRD core: one file per version of the game (World, Japan); each loads only its own version (stream layout in rtl/srd_loader.v,
file sets in tools/srd_sets.py) and a version byte (rom index 1) for the core. To change version, load the other MRA.
Usage: python tools/make_mra.py [output dir, default mra]"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import srd_sets as ss

NL = chr(10)
NAMES = ["Super Real Darwin (World)", "Super Real Darwin (Japan)"]
FILES = ["SRD World.mra", "SRD Japan.mra"]
SETNAMES = ["srdarwin", "srdarwinj"]

def part(entry, offset=None, length=None, indent="        "):
    z, n, c = entry
    a = ' zip="%s" name="%s" crc="%s"' % (z, n, c)       # every part names its zip
    if offset is not None: a += ' offset="0x%x" length="0x%x"' % (offset, length)
    return "%s<part%s />%s" % (indent, a, NL)

def build(outdir):
    os.makedirs(outdir, exist_ok=True)
    paths = []
    w = ss.WORLD
    for v, f in enumerate(ss.SETS):
        name = NAMES[v]
        zips = "srdarwin.zip" if v == 0 else "srdarwinj.zip|srdarwin.zip"
        L = []
        L.append("<misterromdescription>")
        L.append("    <name>%s</name>" % name)
        L.append("    <setname>%s</setname>" % SETNAMES[v])
        L.append("    <rbf>SRD</rbf>")
        L.append("    <mameversion>0266</mameversion>")
        L.append("    <year>1987</year>")
        L.append("    <manufacturer>Data East Corporation</manufacturer>")
        L.append("    <category>Shooter</category>")
        L.append("    <players>2</players>")
        L.append("    <joystick>8-way</joystick>")
        L.append("    <rotation>vertical (ccw)</rotation>")
        L.append('    <buttons names="Button 1,Button 2,Start,Coin" default="A,B,Start,Select" />')
        L.append("")
        L.append("    <!-- This MRA carries the %s version of the game. The other version has its own MRA: load it to change version." % name)
        L.append("         ROM stream (see rtl/srd_loader.v): 0x000000 background tile ROM, 0x020000 sprite ROM, 0x050000 main CPU, character ROM, MCU ROM and sound ROM.")
        L.append("         The files come from %s (in the games folder, /media/fat/games/mame). -->" % zips.replace("|", " and "))
        L.append("")
        L.append('    <rom index="0" zip="%s" md5="none">' % zips)
        L.append("        <!-- background tile ROM: four banks of (dy_03.b4 chunk, dy_02.b5 chunk), 0x4000 bytes each -->")
        t = NL.join(L) + NL
        for k in range(4):
            t += part(w["tlo"], k * 0x4000, 0x4000) + part(w["thi"], k * 0x4000, 0x4000)
        t += "        <!-- sprite ROM, six files in MAME region order -->" + NL
        for sp in ss.SPRITES: t += part(w[sp])
        t += "        <!-- %s: dy_00 (banks 0-3), dy_01 (banks 4-5 and the fixed ROM), character ROM, i8751 MCU ROM, sound ROM -->%s" % (name, NL)
        for k in ("dy00", "dy01", "char", "mcu", "snd"): t += part(f[k])
        t += "    </rom>" + NL
        t += "    <!-- one byte for the core: the version (selects the coin options of the OSD) -->" + NL
        t += '    <rom index="1"><part>%02X</part></rom>%s' % (v, NL)
        t += "</misterromdescription>" + NL
        path = os.path.join(outdir, FILES[v])
        open(path, "w", newline="").write(t); paths.append(path)
    return paths

if __name__ == "__main__":
    print("written", build(sys.argv[1] if len(sys.argv) > 1 else "mra"))
