#!/usr/bin/env python3
"""Prints font facts with fontTools, for the ztk tests.

Usage: python3 -I tools/font-oracle.py <font file>

Each line is "key value...". The Zig tests compare their parser with it.
SPDX-License-Identifier: BSD-2-Clause
"""
import sys
from fontTools.ttLib import TTFont
from fontTools.pens.recordingPen import DecomposingRecordingPen

CHARS = "AVa.1 é€"
PAIRS = ["AV", "To", "LT", "aa"]
OUTLINES = "ABié"


def kerning(font, left, right):
    """The x advance of the first glyph from the pair lookups of the kern feature."""
    gpos = font["GPOS"].table
    lookups = set()
    for fr in gpos.FeatureList.FeatureRecord:
        if fr.FeatureTag == "kern":
            lookups.update(fr.Feature.LookupListIndex)
    total = 0
    for idx in sorted(lookups):
        lookup = gpos.LookupList.Lookup[idx]
        for st in lookup.SubTable:
            if lookup.LookupType == 9:
                st = st.ExtSubTable
            if st.LookupType != 2 if hasattr(st, "LookupType") else False:
                continue
            if not hasattr(st, "Format"):
                continue
            cov = st.Coverage.glyphs
            if left not in cov:
                continue
            if st.Format == 1:
                ps = st.PairSet[cov.index(left)]
                for pvr in ps.PairValueRecord:
                    if pvr.SecondGlyph == right:
                        v = pvr.Value1
                        if v is not None and hasattr(v, "XAdvance") and v.XAdvance:
                            return v.XAdvance
                        return 0
            elif st.Format == 2:
                c1 = st.ClassDef1.classDefs.get(left, 0)
                c2 = st.ClassDef2.classDefs.get(right, 0)
                rec = st.Class1Record[c1].Class2Record[c2]
                v = rec.Value1
                if v is not None and hasattr(v, "XAdvance") and v.XAdvance:
                    return v.XAdvance
                # The first subtable whose coverage has the glyph decides.
                return 0
    return total


def main():
    font = TTFont(sys.argv[1])
    cmap = font.getBestCmap()
    hmtx = font["hmtx"]
    print("upem", font["head"].unitsPerEm)
    print("hhea", font["hhea"].ascent, font["hhea"].descent, font["hhea"].lineGap)
    print("glyphs", font["maxp"].numGlyphs)
    for ch in CHARS:
        g = cmap.get(ord(ch))
        gid = font.getGlyphID(g) if g else 0
        print("char", ord(ch), gid, hmtx[g][0] if g else hmtx[".notdef"][0])
    gs = font.getGlyphSet()
    glyf = font["glyf"]
    for ch in OUTLINES:
        g = cmap[ord(ch)]
        glyph = glyf[g]
        coords, ends, flags = glyph.getCoordinates(glyf)
        print("outline", ord(ch), len(ends), len(coords))
    for pair in PAIRS:
        l, r = cmap[ord(pair[0])], cmap[ord(pair[1])]
        print("kern", pair, kerning(font, l, r))


main()
