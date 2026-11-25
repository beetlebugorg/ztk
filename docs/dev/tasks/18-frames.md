# Task 18: Frame pacing, transitions, statistics, and memory

This task uses the loop of task 04. Its memory part depends on `compact` of ztcl, and has a fallback.

## Goal

The window draws only when something changed. A CSS transition animates at the rate of the display. The program can print frame statistics. The memory of the interpreter does not grow with each event.

## Files

- `src/app.zig`: the frame schedule, `maybeCompact`
- `src/anim.zig`: transitions
- `src/stats.zig`: frame statistics
- `bench/bench.zig`, `build.zig`: the `bench` step
- `src/bind.zig`, `src/loop.zig`: compiled scripts after a compact

## Interfaces

```zig
// src/anim.zig
pub const Anim = struct {
    widget: *Widget,
    from: Style, to: Style,
    start_us: i64, duration_us: i64, linear: bool,
};
/// Starts or changes the animation of a widget after a style change.
pub fn start(app: *App, w: *Widget, old: *const Style, new: *const Style, now_us: i64) !void;
/// Sets the shown style of each animated widget for a time. Returns
/// true when an animation still runs.
pub fn tick(app: *App, now_us: i64) bool;
/// The style that the paint uses: the animated one, or `w.style`.
pub fn shown(app: *App, w: *const Widget) *const Style;
/// The timing function `ease` of CSS: cubic-bezier(0.25, 0.1, 0.25, 1).
pub fn ease(t: f32) f32;

// src/stats.zig
pub const Stage = enum { events, style, layout, paint, render };
pub const Stats = struct {
    pub fn begin(s: *Stats, stage: Stage, now_us: i64) void;
    pub fn end(s: *Stats, stage: Stage, now_us: i64) void;
    pub fn frameDone(s: *Stats, now_us: i64) void;
    /// Prints the counts and the 50th and 99th percentile of each stage.
    pub fn report(s: *const Stats, w: *std.Io.Writer) !void;
    frames: u64 = 0,
    late: u64 = 0,       // frames whose stages needed more than 16 666 us
    first_frame_us: i64 = 0,  // from the process start to the end of the first draw
};

// src/app.zig
/// Calls `compact` of ztcl when the arena grew by more than the
/// threshold and the interpreter is idle. Returns true when it ran.
pub fn maybeCompact(app: *App) bool;
```

## Steps

1. The frame schedule:
   - A dirty flag asks for one frame (task 11).
   - An animation asks for the next frame at the end of each frame, while `tick` returns true.
   - The caret timer of task 15 sets the paint flag of the entry.
   - With no dirty flag, no animation, and no timer, `App.doOneEvent` blocks in `Platform.wait(null)`. The process uses no CPU time.
2. Transitions:
   - In `restyle`, when the style of a widget changes and the new style has `transition.duration_ms > 0`, call `anim.start`. A widget with no old style (a new widget) does not animate.
   - The animated properties are `color`, `background`, `background2`, `border_color`, `outline_color`, `caret_color`, `opacity`, `radius`, and `shadow`. A color is interpolated on its four sRGB channels. The other properties (padding, border width, font) change at once, because they change the layout.
   - A new change during an animation starts from the shown value.
   - `tick` sets the paint flag of each animated widget.
   - `paint` reads `anim.shown`.
   - The `frame` event has the time. Use that time, and not a clock read, so that the headless tests are exact.
   - `ZTK_NO_ANIMATION=1` and `App.Options.animations = false` set each duration to 0. The golden tests of the other tasks use it.
3. Statistics:
   - `ZTK_FRAME_STATS=1` prints the report to stderr at the exit: the frame count, the late count, the time to the first frame, and the percentiles of each stage in microseconds.
   - The time to the first frame starts at the process start. Read the start time first in `main`.
   - `--exit-after-frames N` prints `frames: N` to stdout.
   - Keep the last 4 096 samples of each stage in a ring.
   - A frame whose stages need more than 100 ms prints one line to stderr at once, with the time of each stage. This line needs no environment variable, and it prints at most one time in each second.
   - A backend that writes CPU images gives the count of rows that it wrote. The report has the mean of that count.
4. The benchmark `zig build bench` builds `bench/bench.zig` in `ReleaseFast` and runs these cases on the headless backend with the font of the repository. Each case prints its name, the count of runs, the median, and the 99th percentile in microseconds:
   - `build-1000`: a script makes 1 000 widgets (40 by 25 labels and buttons in a grid) and the first frame draws.
   - `frame-full-1000`: a change of a `:root` variable, so all styles, the layout, and the paint run.
   - `frame-hover-1000`: the pointer moves from one button to the next. One style changes and the paint runs.
   - `frame-text-1000`: the text of one label changes with the same size.
   - `idle-1000`: `App.frame` with no dirty flag.
   - `type-entry`: one key in an entry of the demo.
   - `demo-start`: from `App.init` to the end of the first frame of `examples/demo.tcl` (the file comes in task 19; use the smoke script until then).
   The CPU renderer is not in the frame cases: give the headless backend a flag that skips the draw, and measure `cpu-render-demo` as its own case.
5. Memory of ztk: a test with `std.testing.allocator` makes and deletes 10 000 labels and has no leak. A second test measures the bytes of the allocator for 10 000 labels that exist, and prints the bytes for each label.
6. Memory of the interpreter:
   - Read the bytes that the arena of ztcl holds. Use `Interp.memUsed()` when the pinned ztcl has it. If it does not, use the counter that `mem_limit` checks.
   - `maybeCompact` runs from `App.run` between passes, when `app.callback_depth` is 0. It calls `it.compact(&.{}, .{})` when the arena grew by more than `App.Options.compact_threshold` (default 8 MiB) after the last compact. On `error.InterpBusy` it makes no change and tries again after the next 8 MiB.
   - After a compact, each compiled script is invalid. `App.script_gen` counts up. `bind.zig` and `loop.zig` compile again when their saved generation differs.
   - After a compact, each widget command, each `ztk` command, and each `ctx` must still work. A test checks this: make widgets, compact, and call `.b invoke`, `winfo children .`, and `ztk::style add`. If `compact` loses the `ctx` of a native command, register the commands again after each compact, from the list that the App keeps.
   - If `compact` cannot work at all with the pinned ztcl, turn `maybeCompact` off by default, keep the growth test as a measurement that prints the bytes for each event, and write the facts in `docs/dev/tasks/BLOCKED.md`. That is request 3 of [the plan](../plan.md#10-what-ztk-needs-from-ztcl). The stage does not stop for it.
7. Set a memory limit in the growth test (`it.mem_limit`), so that a failure is an error and not a full machine.

## Tests

```sh
zig build test -Dtest-filter=anim
zig build test -Dtest-filter=stats
zig build test -Dtest-filter=memory
zig build bench
ZTK_FRAME_STATS=1 zig-out/bin/ztk --headless --exit-after-frames 3 tests/scripts/smoke.tcl
```

- `ease(0)` is 0, `ease(1)` is 1, and `ease(0.5)` is between 0.78 and 0.82.
- A button with a 120 ms transition: after the hover, frames at 0, 60, and 120 ms of the manual clock have three different background colors, and the last one is the `:hover` color. A frame at 200 ms does not draw.
- A hover that ends at 60 ms goes back from the shown color, with no jump: the color of the next frame is between the shown color and the normal color.
- With `animations = false`, the first frame after the hover has the end color.
- A transition does not run the layout (count the `arrange` calls).
- Idle: after the last animation frame, 5 000 ms of the manual clock give no frame and no `requestFrame`.
- `Stats.report` of three frames prints `frames: 3` and one line for each stage.
- A frame with a stage of 150 ms on the manual clock prints the slow frame line. A second slow frame in the same second prints no line.
- The labels test has no leak, and each label uses under 1 024 bytes. If it uses more, record the number. Do not change the test limit without the reviewer.
- The interpreter test: `bind . <Motion> {set ::m %x}` and 100 000 motion events through `dispatch.handle`, with `maybeCompact` between each 1 000 events. The arena after the last compact is at most 1 MiB larger than after the first compact.
- The same with a binding that has no `%` field (`incr ::n`): the script compiles one time for each compact generation.
- After a compact: `.b invoke` works, a binding runs, an `after` timer that was pending runs, and a `-textvariable` trace still updates its label.

## Acceptance

- All tests pass, or `BLOCKED.md` has the facts for step 6.
- `zig build bench` prints all cases. `frame-hover-1000` and `frame-text-1000` have a 99th percentile under 4 000 microseconds. `idle-1000` is under 5 microseconds. `demo-start` is under 30 000 microseconds. A case that misses its number goes in the report of task 21 with its value. It does not block the commit.
- The idle test passes: no frame with no change.

## Out of scope

- `@keyframes`, more than one duration, and delays.
- Animations on the render thread. Stage 2.
- Paint of only the changed region.
- Changes to ztcl.
