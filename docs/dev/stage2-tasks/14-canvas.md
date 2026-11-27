# Task 14: `canvas`

## Two PRs

The task has two PRs (a decision for the user, 2026-11-25):

1. PR 14a: the canvas widget (steps 1 to 8), its tests, the bench cases `canvas-10000-scroll` and `canvas-drag`, and a canvas card in the gallery.
2. PR 14b: the two example apps below, with their tests, their gates, and their live cards in the gallery.

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
5. Scrolling: `xview`, `yview`, `-xscrollcommand`, `-yscrollcommand`, `-scrollregion`, `-confine`, and the increments use `src/scroll.zig` of task 07, with its smooth scroll and momentum.
6. The `text` item uses the text engine of Stage 1 (`src/text/`): the shaping, the line breaks, and the glyph atlas.
7. The `image` and `bitmap` items need images. This task adds the stand-in `image create photo` (PNG through `src/base/png.zig`), `image delete`, `image names`, and `image width|height`. Task 09 uses the same stand-in for `-image`.
8. A target of `ztk::animate` can be a canvas item: `ztk::animate {.c 12} -coords {...} -fill red`.

## The two example apps

The user asked for two apps in place of a generic drawing app (2026-11-24). Each app is one readable script with the modern look. Each app runs native and live on the web in the gallery (a live wasm card, with a screenshot as the poster), in light and dark.

1. A spreadsheet, `examples/spreadsheet.tcl`:
   - a grid drawn on the canvas, with items only for the visible cells, smooth scroll through the protocol of task 07, and a frozen header row and column;
   - the selection of a cell and of a range with the mouse and the keyboard (the arrows, Tab, Enter, and Shift with an arrow);
   - editing in place with an `entry` over the cell;
   - formulas evaluated with Tcl: `=A1+B2`, `=sum(A1:A10)`, `=avg()`, `=min()`, `=max()`, and each function of `expr`;
   - dependency tracking and recalculation, with the errors `#REF`, `#DIV/0`, and a cycle shown in the cell;
   - a column resize by a drag of the edge of a header, and number formats;
   - copy and paste of a range as text with tabs, and undo;
   - save and load as CSV through the file capability of the sandbox when the script has it, else in memory, and through the page on the web.
2. A vector graphics tool, `examples/vector.tcl`:
   - the tools select, rectangle, ellipse, line, polyline and polygon, freehand path, and text;
   - a selection with handles to move, resize, and rotate, and a multiple selection with a rubber band and Shift;
   - fill, stroke, stroke width, and opacity in a properties panel, made of the widgets that exist when this task merges;
   - the z-order (raise and lower) or layers, groups, and snap to a grid;
   - zoom and pan with the wheel, a pinch, and a drag with Space held;
   - undo and redo;
   - export to SVG (and PostScript when the canvas has it), and save and load in its own format;
   - a console pane (an `entry` and an output area) that runs Tcl on the document with a small API (`shape rect x y w h -fill red`, `shape list`, `select`, `move`, `each shape {...}`). The script runs in a child interpreter with a compute limit and a memory limit, so that a bad script cannot stop the app. Its errors show in the console. The history of the console has 3 sample scripts, for example a spiral of circles.

The fluid gates apply to both apps: the spreadsheet with 10 000 rows, and the vector tool with 10 000 shapes. Tests drive each app headless: they enter formulas and check the results, draw and transform shapes, run a console script, undo, and export SVG and check it.

Some widgets that the apps need (`menu`, `listbox`, `ttk::notebook`, and `text`) come in later tasks. This task builds the apps with the widgets that exist, and tasks 11, 12, 13, and 15 change the apps to use their widgets.

## Tests

- `zig build test -Dtest-filter=canvas`: each item type, each subcommand, tag expressions, item bindings with `Enter` and `Leave`, `find closest` and `overlapping`, and the messages of `wish`. `canvas.test` and the other `canv*.test` counts go in the PR.

## Animations and the fluid gate

Item moves with `ztk::animate`. A drag of an item follows the pointer in the next frame. The budget: 10 000 items scroll at the full rate. The fluid gate: `canvas-10000-scroll` and `canvas-drag` are under 8 ms.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.
- The two apps run native and in the gallery on the web, and their tests and gates pass.

## Out of scope

- `postscript`.
