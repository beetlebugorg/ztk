# Task 17: The dialogs

## Goal

The dialogs of Tk that need only the widgets of this stage exist, drawn by ztk: `tk_messageBox`, `tk_dialog`, `tk_chooseColor`, `tk_getOpenFile`, `tk_getSaveFile`, and `tk_chooseDirectory`. `ztk::toast` shows a short message.

## Files

- `src/library/*.tcl`: the dialogs, as Tcl scripts of ztk on the widgets of this stage (new code, no copy of the library of Tk)
- `src/tests/dialogs.zig`

## Steps

1. Read `doc/messageBox.n`, `doc/dialog.n`, `doc/chooseColor.n`, `doc/getOpenFile.n`, and `doc/chooseDirectory.n`.
2. Each dialog has the options and the result of its page. It is a toplevel with a `grab`. The file dialogs read the folder only when the program has the file capability (D19). Without it they give an error.
3. `ztk::toast text ?-duration ms?` and an inline banner style for a frame (`banner`).

## Tests

- `zig build test -Dtest-filter=dialogs`: each dialog with keys and the pointer through `event generate`, the results, a cancel, and the messages of `wish`.

## Animations and the fluid gate

A dialog fades and scales in. A toast slides in and out. The fluid gate: `dialog-open` is under 8 ms.

## Acceptance

- The tests of this file pass.
- The checks of [the index](README.md#acceptance-for-each-task) pass, with the modern look, light and dark, and the web build from task 06 on.
- The widgets of the task show in the gallery shots.

## Out of scope

- The native dialogs of D9.
