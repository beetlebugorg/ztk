# Tk

ztk is a new implementation of the script commands of Tk. It has no code of Tk.

## The manual pages and the behavior

Tk, John Ousterhout and the Tcl Core Team. https://www.tcl-lang.org/ and https://github.com/tcltk/tk, tag `core-8-6-16`.

**License:** Tcl/Tk License (BSD style), in the file `license.terms` of the Tk source.

**How ztk uses it:** the manual pages `doc/*.n` define the commands, the options, the algorithms of the geometry managers, and the rules of `bind`. The authors run `wish` 8.6.16 to get the exact results and error messages. The authors do not read the C source or the Tcl library scripts of Tk for an implementation, and copy no code and no default binding script.

## The test files

The `tests/*.test` and `tests/ttk/*.test` files of the Tk source. https://github.com/tcltk/tk/tree/core-8-6-16/tests

**License:** Tcl/Tk License (BSD style)

**How ztk uses it:** the test files measure compatibility. The repository has no copy of them. `tools/fetch-tk.sh` downloads a release into an ignored folder. `tools/tk-count.py`, `tools/tk-introspect.tcl`, and `tools/tk-run.sh` made the counts in [The size of Tk](../dev/tk-size.md).

## Tables of names

The key symbol names and numbers (`keysyms.n`), the color names and values (`colors.n`), and the event types and `%` fields (`bind.n`).

**License:** Tcl/Tk License (BSD style)

**How ztk uses it:** ztk has its own tables with the same names and values, because a script uses these names. Stage 1 has a small part of each table.

## The Tcl interpreter

ztcl. https://github.com/beetlebugorg/ztcl

**License:** BSD-2-Clause

**How ztk uses it:** ztk registers its commands in a ztcl interpreter. The docs of ztk follow the form of the docs of ztcl. `WRITING.md` and `AGENTS.md` are adapted from ztcl.

## The grid algorithm

The section "THE GRID ALGORITHM" of `doc/grid.n` gives the three steps and the rules for weights, uniform groups, and the minimum size. The rules that the page leaves open (the rounding of space, the order of spans, the pad of an empty line) come from runs of `wish` 8.6.16 and from `tools/oracle-grid.tcl`. The authors did not read `tkGrid.c`.

## The text widget

The section "INDICES" of `doc/text.n` gives the forms of an index and its modifiers, and the sections on marks and on `delete` give the gravity of a mark and the rule for the last newline. The prefixes that a modifier accepts, the base of the line numbers, and the messages come from runs of `wish` 8.6.16. The cases are in `src/tests/textw.zig` and `src/text_widget/index.zig`. The authors did not read `tkTextIndex.c` or `tkText.c`.
