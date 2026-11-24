# Task 05: `scale`

## Goal

The classic `scale` works with the pointer, the keyboard, and `-variable`.

## Files

- `src/widgets/scale.zig`, `src/tests/scale.zig`

## Steps

1. Read `doc/scale.n`.
2. All options of `scale.n`, with `-from`, `-to`, `-resolution`, `-digits`, `-tickinterval`, `-bigincrement`, `-showvalue`, `-orient`, `-length`, `-sliderlength`, `-label`, `-variable`, and `-command`.
3. The subcommands `coords`, `get`, `identify`, and `set`.
4. The class bindings of `wish`: a press on the trough moves by one step, a drag on the slider, the arrow keys, `Control` with the arrows, `Home`, and `End`.
5. The parts `::trough`, `::slider`, `::fill` (the track before the slider), and `::value`. The modern theme draws a thin track, a round knob with a shadow, and the fill in the accent color.

## Tests

- `zig build test -Dtest-filter=scale`: options, `get` and `set` with `-resolution` and `-digits`, `coords`, `identify`, the variable, `-command` with the value, the keys, a drag, and the messages of `wish`.
- `scale.test` of Tk runs on `wish` and the counts of the cases that ztk can run go in the PR.

## Animations and the fluid gate

A click on the trough moves the knob with an ease. The drag follows the pointer from the render thread in the next frame. The fluid gate: `scale-drag` is under 8 ms at the 99th percentile.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.

## Out of scope

- `ttk::scale` (task 10).
