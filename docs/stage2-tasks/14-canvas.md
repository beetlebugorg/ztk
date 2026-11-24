# Task 14: `canvas`

## Goal

The `canvas` works with all item types, tags, bindings, `find`, and the transforms of Tk (`move`, `scale`, `coords`).

## Files

- `src/canvas/*.zig`: the items, the tags, the search, and the path rasterizer (coverage spans of section D4 of the plan)
- `src/tests/canvas.zig`

## Steps

1. Read `doc/canvas.n`.
2. The item types: `arc`, `bitmap`, `image`, `line`, `oval`, `polygon`, `rectangle`, `text`, and `window`, with their options (dash, arrows, smooth lines, `-state`, the active and disabled forms).
3. The subcommands: `addtag`, `bbox`, `bind`, `canvasx`, `canvasy`, `cget`, `configure`, `coords`, `create`, `dchars`, `delete`, `dtag`, `find`, `focus`, `gettags`, `icursor`, `imove`, `index`, `insert`, `itemcget`, `itemconfigure`, `lower`, `move`, `moveto`, `raise`, `rchars`, `scale`, `scan`, `select`, `type`, `xview`, and `yview`. `postscript` gives an error in the limits.
4. Tag expressions with `&&`, `||`, `^`, `!`, and parentheses.
5. A target of `ztk::animate` can be a canvas item: `ztk::animate {.c 12} -coords {...} -fill red`.

## Tests

- `zig build test -Dtest-filter=canvas`: each item type, each subcommand, tag expressions, item bindings with `Enter` and `Leave`, `find closest` and `overlapping`, and the messages of `wish`. `canvas.test` and the other `canv*.test` counts go in the PR.

## Animations and the fluid gate

Item moves with `ztk::animate`. A drag of an item follows the pointer in the next frame. The budget: 10 000 items scroll at the full rate. The fluid gate: `canvas-10000-scroll` and `canvas-drag` are under 8 ms.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.

## Out of scope

- `postscript`.
