"""Derive the picker's icon font from lucide.ttf.

Usage: lucide-font-derive.py LUCIDE_TTF OUT_TTF

Ghostty draws a codepoint-mapped glyph at the primary font's size and leaves
its position alone unless the codepoint has a Nerd Font rule. Lucide's
glyphs are 0.92 em circles drawn from the baseline up, so in a Hack cell
(0.6 em wide) they spill into the next cell and sit high. This font holds
only the status and agent-count glyphs, rescaled to the cell width and centred on the
cell, with Hack Nerd Font Mono's metrics so Ghostty applies no size
adjustment (it matches fonts by x-height).

The glyphs are drawn SIZE times the cell width. The icon is followed by a
space, so Ghostty lets it span two cells, and it does not shrink a PUA
glyph without a Nerd Font rule that fits in two; the overshoot spills
evenly into the neighbouring cells. Circle-check therefore lives at
U+E1C0, outside every Nerd Font attribute range: at its Lucide codepoint
(U+E226, Font Awesome Extension) a rule would force it to one cell.
"""

import sys

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.misc.timeTools import timestampFromString
from fontTools.ttLib import TTFont

# Output codepoint -> the Lucide codepoint its glyph is taken from.
CODEPOINTS = {
    0xE1C0: 0xE226,  # circle-check
    0xE4B0: 0xE4B0,
    0xE082: 0xE082,
    0xE07E: 0xE07E,
    0xE1BB: 0xE1BB,
}
FAMILY = "Lucide Picker"
VERSION = "Version 1.000; lucide-static 1.52.0, derived for Hack Nerd Font Mono"

# Hack Nerd Font Mono Regular 3.003 (Nerd Fonts 3.4.0).
UPM = 2048
ADVANCE = 1233
SIZE = 1.15  # widest glyph, in cell widths
ASCENT = 1901
DESCENT = -483
X_HEIGHT = 1120
CAP_HEIGHT = 1493


def main(src, out):
    lucide = TTFont(src)
    cmap = lucide.getBestCmap()
    glyphs = lucide.getGlyphSet()

    # One scale for all glyphs, from the widest box, so they keep their relative size.
    names = [cmap[src] for src in CODEPOINTS.values()]
    boxes = {}
    for name in names:
        pen = BoundsPen(glyphs)
        glyphs[name].draw(pen)
        boxes[name] = pen.bounds
    widest = max(max(b[2] - b[0], b[3] - b[1]) for b in boxes.values())
    scale = SIZE * ADVANCE / widest
    centre_y = (ASCENT + DESCENT) / 2

    order = [".notdef"] + [f"uni{cp:04X}" for cp in CODEPOINTS]
    outlines = {".notdef": TTGlyphPen(None).glyph()}
    metrics = {".notdef": (ADVANCE, 0)}
    for cp, name in zip(CODEPOINTS, names):
        x0, y0, x1, y1 = boxes[name]
        dx = ADVANCE / 2 - (x0 + x1) / 2 * scale
        dy = centre_y - (y0 + y1) / 2 * scale
        pen = TTGlyphPen(None)
        glyphs[name].draw(TransformPen(pen, (scale, 0, 0, scale, dx, dy)))
        glyph = pen.glyph()
        outlines[f"uni{cp:04X}"] = glyph
        metrics[f"uni{cp:04X}"] = (ADVANCE, round(x0 * scale + dx))

    fb = FontBuilder(UPM, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({cp: f"uni{cp:04X}" for cp in CODEPOINTS})
    fb.setupGlyf(outlines)
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=ASCENT, descent=DESCENT, lineGap=0)
    fb.setupOS2(
        version=4,
        sTypoAscender=ASCENT,
        sTypoDescender=DESCENT,
        sTypoLineGap=0,
        usWinAscent=ASCENT,
        usWinDescent=-DESCENT,
        sxHeight=X_HEIGHT,
        sCapHeight=CAP_HEIGHT,
        fsSelection=0x40 | 0x80,  # REGULAR, USE_TYPO_METRICS
    )
    fb.setupNameTable(
        {
            "familyName": FAMILY,
            "styleName": "Regular",
            "uniqueFontIdentifier": f"{FAMILY} Regular",
            "fullName": f"{FAMILY} Regular",
            "psName": FAMILY.replace(" ", "") + "-Regular",
            "version": VERSION,
            "licenseDescription": "ISC License, Copyright (c) Lucide Contributors",
        }
    )
    fb.setupPost(isFixedPitch=1)
    # Fixed timestamps keep the output byte-identical between runs, so setup
    # can check the installed file by checksum.
    fb.font["head"].created = fb.font["head"].modified = timestampFromString(
        "Tue Oct  6 00:00:00 2026"
    )
    fb.font.recalcTimestamp = False
    fb.font.save(out, reorderTables=True)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip().splitlines()[2])
    main(sys.argv[1], sys.argv[2])
