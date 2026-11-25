# Task 03: `checkbutton` and `radiobutton`, and the role of each class

## Goal

The `checkbutton` and the `radiobutton` work as in `wish`, with a modern indicator, the switch style, and the segmented style. Each class has its accessibility role. `examples/gallery.tcl` exists.

## Files

- `src/widgets/check.zig`: both classes, on the code of `label` and `button`
- `src/widget.zig`: the field `role` of `Class`, and a role for each class of Stage 1
- `src/paint.zig`: shapes from coverage spans (the check mark, the dot, the switch knob), so the scene keeps one quad form
- `src/themes/modern.css`, `src/themes/classic.css`
- `src/tests/check.zig`
- `examples/gallery.tcl`, `examples/gallery.css`, `tools/shots.sh`

## Steps

1. Read `doc/checkbutton.n` and `doc/radiobutton.n`.
2. The options of `button` and `-variable`, `-onvalue`, `-offvalue`, `-value`, `-tristatevalue`, `-indicatoron`, `-selectcolor`, `-offrelief`, `-overrelief`, `-selectimage`, `-tristateimage`, `-image` (stored), `-compound`, `-underline`, and `-wraplength`. The default variable of a checkbutton is the global variable with the name of the widget, and of a radiobutton is `selectedButton`, as in `wish`.
3. The subcommands `deselect`, `flash`, `invoke`, `select`, `toggle` (checkbutton only), with the messages of `wish`.
4. A variable trace keeps the `selected` state and the `alternate` state (tristate) up to date.
5. The class bindings of `wish` on the tags `Checkbutton` and `Radiobutton`: the pointer and `space`.
6. The indicator is the part `::indicator`. The modern theme draws a rounded box with a check mark, a circle with a dot, and the switch (`ztk::class .c switch`): a track and a knob. The segmented style (`segmented` on each radiobutton of a group) joins the buttons in a row with one border.
7. The `role` of each class: `frame` group, `label` label, `button` button, `entry` text field, `checkbutton` check box (switch for the style), `radiobutton` radio button.

## Tests

- `zig build test -Dtest-filter=check`: the options and their defaults beside `wish`, `invoke`, `select`, `deselect`, `toggle`, the variable in both directions, tristate, a group of three radiobuttons, the class bindings, `-state disabled`, and the messages of `wish`.
- `xvfb-run -a wish` and `ztk --headless` run the same script and print the same values of the variables after the same events.

## Animations and the fluid gate

The check mark draws in (a stroke that grows), the radio dot grows, the switch knob slides with a spring, and the track color moves. The fluid gate: `check-toggle-1000` is under 8 ms at the 99th percentile.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.

## Out of scope

- `-image` drawing (images come in Stage 2).
