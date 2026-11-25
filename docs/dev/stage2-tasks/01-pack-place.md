# Task 01: `pack` and `place`

## Goal

The geometry managers `pack` and `place` work as in `wish` 8.6.16, beside `grid`, with the same `Manager` interface. `docs/dev/stage2-limits.md` exists.

## Files

- `src/pack.zig`, `src/place.zig`
- `src/layout.zig`: the managers in `destroyed` and in the window size of `.`
- `src/cmds.zig`: the registration
- `src/tests/pack.zig`, `src/tests/place.zig`
- `tools/oracle-pack.tcl`, `tools/oracle-place.tcl`
- `docs/dev/stage2-limits.md`

## Steps

1. Read `doc/pack.n` and `doc/place.n`.
2. `pack` has `configure` (and the short form `pack .a .b`), `forget`, `info`, `propagate`, `content`, `slaves`, and the options `-after`, `-anchor`, `-before`, `-expand`, `-fill`, `-in`, `-ipadx`, `-ipady`, `-padx`, `-pady`, and `-side`. The packing list and the cavity rules follow `pack.n`. A pad can be a list of two values.
3. `place` has `configure`, `forget`, `info`, `content`, `slaves`, and the options `-anchor`, `-bordermode`, `-height`, `-in`, `-relheight`, `-relwidth`, `-relx`, `-rely`, `-width`, `-x`, and `-y`. `place` does not change the requested size of the container.
4. A widget has one manager. `pack .a` after `grid .a` moves it, as in `wish`.
5. The window of `.` gets the requested size of the content of `.` for each manager.
6. The error messages are those of `wish`. Run `wish` for each one.

## Tests

- `zig build test -Dtest-filter=pack` and `-Dtest-filter=place`: the options, `info`, `forget`, `propagate`, the messages, and the geometry of 20 fixed layouts with the numbers of `wish`.
- `tools/oracle.sh tools/oracle-pack.tcl <seed> 200` and the same for `place`: frames of fixed size, random options. The result goes in the PR.
- The fluid gate: a new bench case `pack-resize-1000` (1 000 packed labels, one resize of `.` for each frame) is under 8 ms at the 99th percentile.

## Animations and the fluid gate

None. A resize of `.` is a layout of each frame, and the gate measures it.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.

## Out of scope

- `-in` for a container in another toplevel (task 04 adds toplevels).
- The geometry managers of the canvas, the text widget, and the paned window.
