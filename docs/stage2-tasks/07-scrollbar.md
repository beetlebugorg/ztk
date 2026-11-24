# Task 07: Scrolling and `scrollbar`

## Goal

The scroll protocol of Tk works: `-xscrollcommand`, `-yscrollcommand`, `xview`, and `yview`. The classic `scrollbar` exists, with the overlay look of the modern theme. `entry` gets `xview` and `-xscrollcommand`.

## Files

- `src/scroll.zig`: the shared code for `xview` and `yview` (`moveto`, `scroll n units|pages`), the smooth scroll, and the momentum
- `src/widgets/scrollbar.zig`, `src/widgets/entry.zig`
- `src/tests/scrollbar.zig`

## Steps

1. Read `doc/scrollbar.n` and the `xview` parts of `doc/entry.n`.
2. `scrollbar` with all options of `scrollbar.n` and the subcommands `activate`, `delta`, `fraction`, `get`, `identify`, and `set`. The class bindings: arrows, a press on the trough, a drag of the thumb, and the wheel.
3. A wheel event goes to the widget under the pointer. A fractional delta scrolls by the fraction. A touchpad scroll has momentum after the fingers lift.
4. The modern theme: a thin thumb over the content, shown during a scroll and on hover, hidden after a delay. The classic theme: arrows, a trough, and a raised thumb.

## Tests

- `zig build test -Dtest-filter=scrollbar`: options, `set` and `get`, `fraction`, `delta`, `identify`, the callback text of `-command` (`moveto f`, `scroll n units`), and an entry with a long text that scrolls with its scrollbar.

## Animations and the fluid gate

`yview moveto` and a wheel step scroll with an ease, and a touchpad scroll with momentum. The overlay thumb fades in and out. The fluid gate: `scroll-wheel` is under 8 ms at the 99th percentile.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.

## Out of scope

- `ttk::scrollbar` (task 10).
