# Terminal

The terminal state of `ztk::terminal` is libghostty-vt 1.0.2 through `ztcl.vt` (`src/term/core.zig`). The keys, the mouse reports, the drawing, and the selection are ztk code in `src/term/`. The old parser and state (`src/term/parser.zig` and `src/term/screen.zig`) stay for the benchmark until a follow-up PR removes them.

| Source | License | How ztk uses it |
|---|---|---|
| Paul Williams, "A parser for DEC's ANSI-compatible video terminals", https://vt100.net/emu/dec_ansi_parser | The text is the author's. ztk uses the state diagram and has no copy of the text. | The states and the transitions of `src/term/parser.zig` |
| ECMA-48, 5th edition (1991), "Control Functions for Coded Character Sets" | Free standard of Ecma International | The control functions: CUP, ED, EL, ICH, DCH, IL, DL, SGR, and the others |
| DEC VT100 and VT220 manuals, https://vt100.net/docs/ | The manuals of Digital Equipment Corporation. ztk uses the behavior. | The scroll region, the origin mode, the autowrap, the tab stops, and the DEC special graphics set |
| Edward Moy, Stephen Gildea, Thomas Dickey, "XTerm Control Sequences", https://invisible-island.net/xterm/ctlseqs/ctlseqs.html | The text is the authors'. ztk uses the behavior. | The private modes (1049, 1000 to 1006, 2004), the key sequences of `src/term/keys.zig`, the mouse reports, and the OSC color queries |
| Unicode Character Database: `EastAsianWidth.txt` and the general categories | Unicode License v3 | The ranges of wide and zero-width code points in `src/term/width.zig`, in a short form |
| Ghostty, https://github.com/ghostty-org/ghostty, tag `vt-1.0.2` | MIT, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors | libghostty-vt is the parser and the state of the terminal. ztcl pins it and builds it (`docs/references/ghostty.md` of ztcl). ztk copies no code of Ghostty. |
