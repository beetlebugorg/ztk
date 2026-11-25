# Task 08: `entry` additions and `spinbox`

## Goal

The `entry` gets the options and subcommands that Stage 1 left out, the placeholder, and the search style. The classic `spinbox` exists.

## Files

- `src/widgets/entry.zig`, `src/widgets/spinbox.zig`, `src/clipboard.zig`
- `src/tests/spinbox.zig`, `src/tests/entry2.zig`

## Steps

1. Read `doc/entry.n`, `doc/spinbox.n`, `doc/clipboard.n`, and `doc/selection.n`.
2. `entry`: `-validate`, `-validatecommand`, `-invalidcommand`, the disabled and read-only colors, `-highlight*`, `-insertbackground`, `bbox`, `scan`, `validate`, `selection adjust`, `from`, and `to`, the clipboard and the virtual events `<<Cut>>`, `<<Copy>>`, `<<Paste>>`, `<<SelectAll>>`, and undo.
3. Additions: `-placeholder` (a muted text while the entry is empty) and the `search` style (a search mark and a clear button).
4. `spinbox` with all options of `spinbox.n`, `-from`, `-to`, `-increment`, `-values`, `-wrap`, `-format`, `-command`, and the subcommands of `entry` with `invoke`. Arrow keys, the buttons, and the button repeat.

## Tests

- `zig build test -Dtest-filter=spinbox` and `entry2`: options, validation modes, `%` fields of `-validatecommand`, the clipboard, the values list, `-wrap`, `-format`, the repeat, and the messages of `wish`.

## Animations and the fluid gate

The placeholder fades. The arrow buttons of a spinbox have the hover and pressed transitions. The fluid gate: `type-entry` stays under 8 ms.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.

## Out of scope

- `ttk::spinbox` (task 10).
