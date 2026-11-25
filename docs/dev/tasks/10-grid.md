# Task 10: `grid`

## Goal

The `grid` geometry manager places widgets in rows and columns, with the results of `wish` 8.6.16 for the same script. This task computes the layout. It draws no picture.

## Files

- `src/layout.zig`: `Manager`, the layout pass
- `src/grid.zig`: the solver and the `grid` command
- `src/widget.zig`: `Widget.manager`, `Widget.manager_data`, `Widget.container_data`
- `src/cmds.zig`: `winfo manager`
- `tools/oracle.sh`, `tools/oracle-grid.tcl`

## Interfaces

```zig
// src/layout.zig
pub const Manager = struct {
    name: []const u8,   // "grid"; the result of `winfo manager`
    /// Sets the requested size of the container from its content.
    measure: *const fn (container: *Widget) void,
    /// Sets `geom` and `mapped` of each managed widget of the container.
    arrange: *const fn (container: *Widget) void,
    /// The manager stops managing the widget (it is deleted, or another
    /// manager gets it).
    forget: *const fn (w: *Widget) void,
};
/// Measures bottom-up and arranges top-down, for the widgets with the
/// measure or layout flag. Returns true when a geometry changed.
pub fn run(top: *Widget) bool;

// src/grid.zig
pub const manager: layout.Manager;
pub const Sticky = packed struct(u8) { n: bool = false, e: bool = false, s: bool = false, w: bool = false, _pad: u4 = 0 };
pub const Cell = struct {          // the grid data of one managed widget
    column: u16, row: u16, columnspan: u16 = 1, rowspan: u16 = 1,
    padx: [2]i32 = .{ 0, 0 }, pady: [2]i32 = .{ 0, 0 },
    ipadx: i32 = 0, ipady: i32 = 0,
    sticky: Sticky = .{},
    in: *Widget,
};
pub const Line = struct {          // one row or one column of a container
    minsize: i32 = 0, pad: i32 = 0, weight: i32 = 0, uniform: []const u8 = "",
};
/// The solver for one axis. It is a pure function.
/// `items` have the first line, the span, and the size that the widget
/// needs on this axis with its padding. The result is the offset of each
/// line boundary: `offsets[i]` is the start of line i, and
/// `offsets[lines.len]` is the end.
pub const Item = struct { first: u16, span: u16, size: i32 };
pub fn solve(gpa: std.mem.Allocator, lines: []const Line, items: []const Item, available: ?i32, offsets: []i32) !void;
pub fn command(it: *ztcl.Interp, argv: []const ztcl.Value, cmd: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value;
```

```zig
// added to Widget
manager: ?*const layout.Manager = null,
manager_data: ?*anyopaque = null,     // for grid: *grid.Cell
container_data: ?*anyopaque = null,   // for grid: the lines, the propagate flag, the anchor
```

## Steps

1. Run `tools/fetch-tk.sh` and read `doc/grid.n`. The section "THE GRID ALGORITHM" gives the three steps: compute the minimum size, compare it with the size of the container, and place each widget by its `-sticky`. Implement what the page says. Where the page does not give a rule (the rounding of space that weights divide), find the rule with experiments in `wish`. Do not read the C source of Tk.
2. `solve`, as the manual page says:
   - With `available == null`, compute the minimum layout. A line has at least its `minsize`. An item with a span of 1 makes its line at least its size plus the `pad` of the line. Lines in one `uniform` group get sizes in proportion to their weights (a weight of 0 counts as 1). An item with a larger span adds space to its lines by their weights, or equally when all the weights are 0.
   - With `available`, add the extra space to the lines by their weights. With all weights 0, the layout keeps its minimum size. When `available` is smaller, remove space by the weights. A line that reaches its `minsize` stops shrinking.
3. Placement of one widget in its cell area, after the padding is removed: with `-sticky ""` the widget has its requested size plus `ipad` and is in the center. `w` or `e` puts it at that side. `we` stretches it. The same for `n` and `s`.
4. When the layout is smaller or larger than the container and no weight uses the difference, the anchor of the container places the layout. The default anchor is `nw`.
5. `measure` sets the requested size of the container to the minimum layout plus the internal padding of the container (its border and padding from the style), unless `propagate` is off. For `.`, the requested size becomes the window size in task 11.
6. The command forms. Each message below is from `wish` 8.6.16:
   - `grid path ?path ...? ?options?` and `grid configure path ...`. Options: `-column`, `-columnspan`, `-in`, `-ipadx`, `-ipady`, `-padx`, `-pady`, `-row`, `-rowspan`, `-sticky`. A wrong one gives `bad option "-bogus": must be -column, -columnspan, -in, -ipadx, -ipady, -padx, -pady, -row, -rowspan, or -sticky`.
   - Without `-row`, a new row after the last used row gets the widgets of one command. Without `-column`, the columns count up from 0 in the command.
   - The relative placement words: `-` extends the widget before it by one column, `x` leaves a column empty, and `^` extends the widget of the row above. `grid .a ^` with no widget above gives `can't find slave to extend with "^"`.
   - `-padx` and `-pady` accept one number or a list of two (left and right, or top and bottom). Three parts give `wrong number of parts to pad specification`.
   - `-sticky` accepts the letters `n`, `e`, `s`, `w` with optional spaces and commas. A wrong letter gives `bad stickyness value "q": must be a string containing n, e, s, and/or w`.
   - `-row x` gives `bad row value "x": must be a non-negative integer`. `-columnspan 0` gives `bad columnspan value "0": must be a positive integer`.
   - `grid forget path ...`, `grid remove path ...` (keeps the options for the next `grid path`).
   - `grid info path` gives `-in . -column 0 -row 1 -columnspan 2 -rowspan 1 -ipadx 0 -ipady 0 -padx 0 -pady 0 -sticky ew`. A pad with two different values prints as a list: `-padx {4 6}`. A widget that grid does not manage gives an empty string.
   - `grid columnconfigure container index ?option value ...?` and `grid rowconfigure`. With no option: `-minsize 0 -pad 0 -uniform {} -weight 0`. With one option: its value. The index can be a list of indexes, the word `all`, or a widget path. A negative weight gives `invalid arg "-weight": should be non-negative`. A wrong option gives `bad option "-bogus": must be -minsize, -pad, -uniform, or -weight`.
   - `grid size container` gives `columns rows`.
   - `grid slaves container ?-row n? ?-column n?` gives the widgets with the newest first. `grid content` is the same.
   - `grid propagate container ?boolean?`.
   - `grid anchor container ?anchor?`.
   - `grid bbox container ?column row? ?column2 row2?`.
   - `grid location container x y`.
   - `grid` alone, or with a bad first word that is not a path, gives `wrong # args: should be "grid option arg ?arg ...?"`. A path that does not exist gives `bad window path name ".zz"`.
7. `-in`: the default container is the parent. Another container must be the parent or a descendant of the parent. In all other cases: `can't put .a.in inside .c`. `grid .a -in .a` gives `window can't be managed in itself`. `grid .` gives `can't manage ".": it's a top-level window`.
8. A widget has one manager. `grid` of a widget that another manager has calls `forget` of that manager first. `destroy` calls `forget`.
9. A `grid` change sets the measure flag of the container and of its ancestors up to the toplevel. `layout.run` goes bottom-up for `measure` and top-down for `arrange`.
10. A widget is `mapped` when grid manages it, its container is mapped, and its size is at least 1 by 1. `.` is mapped from the start in this task.
11. `winfo manager path` gives `grid` or an empty string.
12. The oracle:
    - `tools/oracle-grid.tcl seed count` makes `count` layouts from a seed. It uses its own integer generator (`set s [expr {($s * 1103515245 + 12345) & 0x7fffffff}]`), so `wish` and ztk make the same layouts. Each layout is a `frame .c -width W -height H` with `grid propagate .c` on or off, and 2 to 8 frames inside with a fixed `-width` and `-height`, random rows, columns, spans, `-sticky`, `-padx`, `-pady`, `-ipadx`, `-ipady`, and random `-weight`, `-minsize`, `-pad`, and `-uniform` on some lines. It grids `.c` in `.`, calls `update`, prints one line for each widget with `winfo x`, `y`, `width`, `height`, and the `grid bbox` of `.c`, and deletes `.c`.
    - `tools/oracle.sh script args` runs the script with `xvfb-run -a wish` and with the ztk test runner, and prints the difference. It exits with status 0 when the outputs are equal, 1 when they differ, and 77 when `wish` or `xvfb-run` is not on the path.
    - Until task 17, "the ztk test runner" is a small test program in `build.zig` (`zig build oracle-runner`) that runs a script on the headless backend and prints the output of `puts`.

## Tests

```sh
zig build test -Dtest-filter=grid
zig build oracle-runner && tools/oracle.sh tools/oracle-grid.tcl 1 200
tools/oracle.sh tools/oracle-grid.tcl 2 200
```

Unit tests of `solve`:

- Two lines, items of 30 and 50, no weight, `available` null: offsets 0, 30, 80.
- The same with `available` 100 and weights 1 and 1: offsets 0, 40, 100.
- The same with `available` 100 and weights 0 and 0: offsets 0, 30, 80.
- One item with span 2 and size 100 over two empty lines with weights 0: offsets 0, 50, 100.
- A `uniform` group with weights 1 and 2 and items of 30 and 30: sizes 30 and 60.
- `minsize` 40 on a line with an item of 10 gives 40.
- Shrink: lines of 50 and 50, weights 1 and 1, `available` 60: sizes 30 and 30. With `minsize` 45 on the first: 45 and 15.
- One item with span 2 and size 100, and `minsize` 40 on the first line, weights 0: sizes 70 and 30. The extra 60 is divided equally.
- A `uniform` group with weights 1 and 2, items of 30 and 30, and `available` 200: sizes 66 and 134.

`wish` 8.6.16 gave each of these values, except the first `uniform` case, which follows the manual page. Check that case with `wish` before you rely on it.

Script tests with a `Harness`. The values are from `wish` 8.6.16:

```tcl
frame .a -width 30 -height 20; frame .b -width 50 -height 10
frame .c -width 10 -height 40
grid .a .b; grid .c - -sticky ew; update
```

- `grid size .` gives `2 2`. `grid bbox .` gives `0 0 80 60`.
- `winfo reqwidth .` gives `80` and `winfo reqheight .` gives `60`. (`winfo` of sizes comes in task 11. Read `w.req` and `w.geom` in this test.)
- The geometry of `.a` is 30 by 20 at (0, 0). `.b` is 50 by 10 at (30, 5). `.c` is 80 by 40 at (0, 20).
- `grid info .c` gives the text of step 6. `grid slaves .` gives `.c .b .a`. `grid slaves . -row 0` gives `.b .a`.
- `grid forget .b; grid slaves .` gives `.c .a`, and `grid info .b` is empty.
- `grid remove .a; grid .a; grid info .a` gives column 0 and row 0 again.
- `grid bbox . 0 0` gives `0 0 30 20`.
- Each error message of steps 6 and 7.

In this task, the frames of the tests need a style with no border and no padding. Add a sheet in the test: `Frame { border-width: 0; padding: 0 }`. The oracle runner adds the same sheet.

## Acceptance

- All unit and script tests pass.
- Both oracle commands print no difference for 200 layouts each. When a layout differs and the rule cannot be found, write the smallest script that shows it in `docs/dev/tasks/BLOCKED.md`, with both outputs. The reviewer decides.
- The solver allocates no memory for a container with at most 32 lines on each axis.
- A layout pass for one container with 1 000 widgets in a 40 by 25 grid is under 1 ms in `ReleaseFast`. Print the time in a test with the name `grid-speed`.

## Out of scope

- `pack` and `place`. Stage 2.
- The 195 tests of `grid.test` of Tk. Stage 2 runs them.
- Painting.
