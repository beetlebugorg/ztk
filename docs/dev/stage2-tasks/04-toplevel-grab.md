# Task 04: `labelframe`, `message`, `toplevel`, `grab`, focus traversal, and `ztk::tooltip`

## Goal

A program can have more than one toplevel window. `labelframe` and `message` exist. `grab` and the full focus traversal work. `ztk::tooltip` shows a tooltip.

## Files

- `src/widgets/toplevel.zig`, `src/app.zig`: one platform window and one frame for each toplevel
- `src/widgets/labelframe.zig`, `src/widgets/message.zig`
- `src/grab.zig`, `src/focus.zig`
- `src/tooltip.zig`
- `src/tests/toplevel.zig`, `src/tests/grab.zig`

## Steps

1. Read `doc/toplevel.n`, `doc/labelframe.n`, `doc/message.n`, `doc/grab.n`, `doc/focusNext.n`, and `doc/wm.n`.
2. `toplevel` with the options of `frame` and `-menu`, `-screen`, `-use`, and `-container` (the last three stored). Each toplevel has its own window, scene, and frame. `wm` and `winfo` take any toplevel. `wm transient`, `wm overrideredirect`, `wm attributes`, and `wm iconify` work where the backend has them. The headless backend keeps a list of windows, and `--screenshot` writes `.`.
3. `labelframe` with `-text`, `-labelanchor`, and `-labelwidget`. `message` with `-aspect`, `-justify`, and `-width`, and the line breaks of `message.n`.
4. `grab`, `grab set`, `grab release`, `grab current`, `grab status`, and `-global` (local only, with a note in the limits).
5. `tk_focusNext`, `tk_focusPrev`, `tk_focusFollowsMouse`, `<<NextWindow>>`, and `<<PrevWindow>>`.
6. `ztk::tooltip path ?text?`: a small window with a round corner and a shadow, after a hover of 600 ms, until a leave or a press.

## Tests

- `zig build test -Dtest-filter=toplevel`, `grab`, `labelframe`, `message`, and `tooltip`: options, `wm` on a second toplevel, destroy of a toplevel, a grab that sends the pointer events to its tree, focus traversal over two toplevels, and the messages of `wish`.

## Animations and the fluid gate

A toplevel fades in. A tooltip fades in and out. The fluid gate: `toplevel-open` (a new toplevel with 50 widgets) shows in one frame.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.

## Out of scope

- Window embedding (`-use`, `-container`).
