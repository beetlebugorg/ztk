# The size of Tk

This page has the measured size of Tk 8.6.16 (tag `core-8-6-16`) and of Tk 9.1.0 (tag `core-9-1-0`). The date of the measurement is 2026-11-23. The repository has no copy of Tk.

## How to measure

```sh
tools/fetch-tk.sh core-8-6-16                   # downloads to .tk-src/core-8-6-16
python3 -I tools/tk-count.py .tk-src/core-8-6-16   # manual pages and test lines
xvfb-run -a wish tools/tk-introspect.tcl        # commands, options, subcommands
xvfb-run -a tools/tk-run.sh .tk-src/core-8-6-16 /tmp/tk-run   # the tests on a real wish
```

- `tools/tk-count.py` reads text only. It counts the `.OP` entries of each manual page and the lines that start with `test` in each test file.
- `tools/tk-introspect.tcl` asks a real `wish` 8.6.16. It counts the result of `configure` for each widget class and reads the subcommand list from the error message of a wrong subcommand.
- `tools/tk-run.sh` runs each test file in its own `wish` process, with the constraints file of Tk and a limit of 180 seconds. The X server was `Xvfb` with no window manager. The `wish` is the system package, so it has no `test*` commands of the Tk test binary.

## Commands and options (Tk 8.6.16)

| What | Count |
|---|---|
| Manual pages `doc/*.n` | 87 pages, 25 088 lines |
| Manual pages `doc/*.3` (the C API) | 87 pages |
| `.OP` entries in the `.n` pages (options that a page defines) | 318 |
| Standard options in `options.n` | 42 |
| Standard options in `ttk_widget.n` | 16 |
| Global commands that `wish` adds to `tclsh` | 55 |
| Commands in the `::ttk` namespace | 47 |
| Classic widget classes | 18 |
| Options of the 18 classic classes (sum of `configure`) | 542 |
| Widget subcommands of the 18 classic classes | 174 |
| `ttk` widget classes | 18 |
| Options of the 18 `ttk` classes | 226 |
| Widget subcommands of the 18 `ttk` classes | 170 |
| Canvas item types, item options | 9, 160 |
| Menu entry types, entry options | 5, 73 |
| Text tag options | 27 |
| `wm`, `winfo` subcommands | 32, 49 |
| `font`, `image`, `event` subcommands | 8, 8, 4 |
| `grid`, `pack`, `place` subcommands | 13, 6, 5 |
| `clipboard`, `selection`, `grab`, `option` subcommands | 3, 4, 4, 4 |
| `tk`, `ttk::style` subcommands | 8, 6 |
| Photo image subcommands | 11 |
| Event types in `bind.n` | 28 |
| `%` fields in `bind.n` | 32 |
| Predefined virtual events (`event info`) | 32 |
| Class bindings of the 18 classic classes and `all` | 378 |
| Class bindings of the `ttk` classes | 281 |
| Named colors in `colors.n` | 760 |
| Key symbols in `keysyms.n` | 1 615 |
| `ttk` themes on X11 | 4 (`clam`, `alt`, `default`, `classic`) |
| Elements of the `default` theme | 39 |
| Image types | 2 (`photo`, `bitmap`) |

The classes with the most options are `spinbox` (49), `text` (44), `checkbutton` (41), and `radiobutton` (40). The classes with the most subcommands are `canvas` (33), `treeview` (28), and `text` (26).

## Source lines

`cat <folder>/*.[chm] <folder>/*.tcl | wc -l`, with no subfolders.

| Folder | Tk 8.6.16 | Tk 9.1.0 |
|---|---|---|
| `generic` | 163 963 | 176 239 |
| `generic/ttk` | 26 348 | 33 362 |
| `unix` | 26 792 | 34 661 |
| `win` | 39 372 | 47 766 |
| `macosx` | 42 232 | 46 058 |
| `xlib` | 1 759 | 1 731 |
| `library` | 17 012 | 30 102 |
| `library/ttk` | 4 709 | 8 261 |
| **Sum** | **322 187** | **378 180** |

## Tk 9.1.0

| What | Count |
|---|---|
| Manual pages `doc/*.n` | 93 pages, 28 643 lines |
| `.OP` entries | 340 |
| Test files | 119 |
| `test` lines | 12 016 |

New manual pages: `accessible.n`, `attribtable.n`, `fileicon.n`, `nsimage.n`, `print.n`, `sysnotify.n`, `systray.n`, and `ttk_toggleswitch.n`. Removed: `menubar.n` and `pack-old.n`. This machine has no `wish` 9, so the plan has no run of these tests.

## The tests of Tk 8.6.16

- **Test lines** is the count of lines that start with `test`. A test in a loop counts one time.
- **Total**, **Pass**, **Skip**, and **Fail** are the counts that `tcltest` printed for the real `wish`.
- **Scope** is `Windows` for a `win*` file, `X11` for a `unix*` file, and `ttk` for a file of the `ttk` folder.

The first run had 8 781 passes and 57 failures. The run in this table had one more failure. So at least one test is not stable on this machine.

| File | Scope | Test lines | Total | Pass | Skip | Fail |
|---|---|---|---|---|---|---|
| `bell.test` | all | 8 | 8 | 8 | 0 | 0 |
| `bgerror.test` | all | 3 | 3 | 3 | 0 | 0 |
| `bind.test` | all | 544 | 544 | 537 | 7 | 0 |
| `bitmap.test` | all | 7 | 7 | 2 | 5 | 0 |
| `border.test` | all | 14 | 14 | 7 | 7 | 0 |
| `busy.test` | all | 56 | 56 | 51 | 5 | 0 |
| `button.test` | all | 402 | 402 | 388 | 14 | 0 |
| `canvImg.test` | all | 84 | 84 | 11 | 73 | 0 |
| `canvMoveto.test` | all | 8 | 8 | 8 | 0 | 0 |
| `canvPs.test` | all | 11 | 11 | 10 | 1 | 0 |
| `canvRect.test` | all | 52 | 52 | 51 | 1 | 0 |
| `canvText.test` | all | 98 | 98 | 89 | 9 | 0 |
| `canvWind.test` | all | 5 | 5 | 5 | 0 | 0 |
| `canvas.test` | all | 137 | 137 | 135 | 2 | 0 |
| `choosedir.test` | all | 14 | 14 | 13 | 1 | 0 |
| `clipboard.test` | all | 41 | 41 | 41 | 0 | 0 |
| `clrpick.test` | all | 16 | 16 | 16 | 0 | 0 |
| `cmds.test` | all | 6 | 6 | 6 | 0 | 0 |
| `color.test` | all | 21 | 21 | 4 | 17 | 0 |
| `config.test` | all | 242 | 242 | 27 | 215 | 0 |
| `cursor.test` | all | 100 | 100 | 84 | 16 | 0 |
| `dialog.test` | all | 6 | 6 | 6 | 0 | 0 |
| `embed.test` | all | 7 | 7 | 5 | 2 | 0 |
| `entry.test` | all | 294 | 294 | 261 | 33 | 0 |
| `event.test` | all | 19 | 19 | 18 | 1 | 0 |
| `filebox.test` | all | 35 | 104 | 96 | 8 | 0 |
| `focus.test` | all | 58 | 58 | 25 | 33 | 0 |
| `focusTcl.test` | all | 42 | 42 | 42 | 0 | 0 |
| `font.test` | all | 292 | 292 | 255 | 33 | 4 |
| `fontchooser.test` | all | 19 | 19 | 19 | 0 | 0 |
| `frame.test` | all | 186 | 186 | 173 | 13 | 0 |
| `geometry.test` | all | 14 | 14 | 14 | 0 | 0 |
| `get.test` | all | 15 | 15 | 15 | 0 | 0 |
| `grab.test` | all | 29 | 29 | 28 | 1 | 0 |
| `grid.test` | all | 195 | 195 | 193 | 2 | 0 |
| `image.test` | all | 56 | 56 | 23 | 32 | 1 |
| `imgBmap.test` | all | 60 | 60 | 60 | 0 | 0 |
| `imgPNG.test` | all | 7 | 7 | 7 | 0 | 0 |
| `imgPPM.test` | all | 34 | 34 | 34 | 0 | 0 |
| `imgPhoto.test` | all | 149 | 149 | 145 | 4 | 0 |
| `listbox.test` | all | 376 | 376 | 340 | 36 | 0 |
| `main.test` | all | 7 | 7 | 7 | 0 | 0 |
| `menu.test` | all | 536 | 536 | 527 | 9 | 0 |
| `menuDraw.test` | all | 65 | 65 | 57 | 8 | 0 |
| `menubut.test` | all | 106 | 106 | 90 | 16 | 0 |
| `message.test` | all | 52 | 52 | 52 | 0 | 0 |
| `msgbox.test` | all | 63 | 63 | 61 | 2 | 0 |
| `obj.test` | all | 4 | 4 | 4 | 0 | 0 |
| `oldpack.test` | all | 105 | 105 | 105 | 0 | 0 |
| `option.test` | all | 104 | 104 | 104 | 0 | 0 |
| `pack.test` | all | 193 | 193 | 190 | 1 | 2 |
| `packgrid.test` | all | 18 | 18 | 18 | 0 | 0 |
| `panedwindow.test` | all | 427 | 427 | 425 | 2 | 0 |
| `place.test` | all | 55 | 55 | 52 | 1 | 2 |
| `raise.test` | all | 34 | 34 | 21 | 13 | 0 |
| `safe.test` | all | 16 | 16 | 16 | 0 | 0 |
| `safePrimarySelection.test` | all | 60 | 60 | 60 | 0 | 0 |
| `scale.test` | all | 208 | 208 | 190 | 18 | 0 |
| `scrollbar.test` | all | 139 | 178 | 145 | 33 | 0 |
| `select.test` | all | 111 | 111 | 95 | 16 | 0 |
| `send.test` | all | 74 | 74 | 14 | 60 | 0 |
| `spinbox.test` | all | 318 | 318 | 291 | 27 | 0 |
| `text.test` | all | 692 | 692 | 685 | 7 | 0 |
| `textBTree.test` | all | 138 | 138 | 138 | 0 | 0 |
| `textDisp.test` | all | 397 | 397 | 394 | 3 | 0 |
| `textImage.test` | all | 26 | 26 | 25 | 1 | 0 |
| `textIndex.test` | all | 190 | 190 | 148 | 42 | 0 |
| `textMark.test` | all | 46 | 46 | 46 | 0 | 0 |
| `textTag.test` | all | 175 | 175 | 175 | 0 | 0 |
| `textWind.test` | all | 112 | 112 | 112 | 0 | 0 |
| `tk.test` | all | 37 | 37 | 36 | 1 | 0 |
| `ttk/checkbutton.test` | ttk | 8 | 8 | 8 | 0 | 0 |
| `ttk/combobox.test` | ttk | 15 | 15 | 15 | 0 | 0 |
| `ttk/entry.test` | ttk | 37 | 37 | 37 | 0 | 0 |
| `ttk/image.test` | ttk | 5 | 5 | 5 | 0 | 0 |
| `ttk/labelframe.test` | ttk | 19 | 19 | 19 | 0 | 0 |
| `ttk/layout.test` | ttk | 2 | 2 | 2 | 0 | 0 |
| `ttk/notebook.test` | ttk | 58 | 58 | 58 | 0 | 0 |
| `ttk/panedwindow.test` | ttk | 38 | 38 | 38 | 0 | 0 |
| `ttk/progressbar.test` | ttk | 14 | 14 | 14 | 0 | 0 |
| `ttk/radiobutton.test` | ttk | 8 | 8 | 8 | 0 | 0 |
| `ttk/scrollbar.test` | ttk | 9 | 9 | 6 | 3 | 0 |
| `ttk/spinbox.test` | ttk | 31 | 31 | 26 | 5 | 0 |
| `ttk/treetags.test` | ttk | 23 | 23 | 23 | 0 | 0 |
| `ttk/treeview.test` | ttk | 106 | 106 | 106 | 0 | 0 |
| `ttk/ttk.test` | ttk | 81 | 97 | 97 | 0 | 0 |
| `ttk/validate.test` | ttk | 32 | 32 | 26 | 6 | 0 |
| `ttk/vsapi.test` | ttk | 3 | 3 | 0 | 3 | 0 |
| `unixButton.test` | X11 | 12 | 12 | 6 | 6 | 0 |
| `unixEmbed.test` | X11 | 56 | 56 | 21 | 21 | 14 |
| `unixFont.test` | X11 | 49 | 49 | 35 | 0 | 14 |
| `unixMenu.test` | X11 | 122 | 122 | 117 | 5 | 0 |
| `unixSelect.test` | X11 | 19 | 19 | 17 | 0 | 2 |
| `unixWm.test` | X11 | 261 | 281 | 204 | 70 | 7 |
| `util.test` | all | 12 | 12 | 12 | 0 | 0 |
| `visual.test` | all | 40 | 40 | 14 | 26 | 0 |
| `visual_bb.test` | all | 2 | 1 | 0 | 1 | 0 |
| `winButton.test` | Windows | 9 | 9 | 0 | 9 | 0 |
| `winClipboard.test` | Windows | 8 | 8 | 0 | 8 | 0 |
| `winDialog.test` | Windows | 75 | 73 | 0 | 73 | 0 |
| `winFont.test` | Windows | 30 | 30 | 0 | 30 | 0 |
| `winMenu.test` | Windows | 144 | 144 | 1 | 143 | 0 |
| `winMsgbox.test` | Windows | 19 | 19 | 0 | 19 | 0 |
| `winSend.test` | Windows | 51 | 51 | 0 | 51 | 0 |
| `winWm.test` | Windows | 30 | 30 | 0 | 29 | 1 |
| `window.test` | Windows | 18 | 18 | 13 | 5 | 0 |
| `winfo.test` | Windows | 71 | 71 | 63 | 6 | 2 |
| `wm.test` | all | 285 | 285 | 243 | 33 | 9 |
| `xmfbox.test` | all | 8 | 8 | 8 | 0 | 0 |
| **109 files** | | **10080** | **10221** | **8780** | **1383** | **58** |

The constraints that skipped the most tests on the real `wish`:

| Constraint | Tests | Meaning |
|---|---|---|
| `win` | 336 | Windows only |
| `testobjconfig` | 215 | A command of the Tk test binary |
| `testImageType` | 145 | A command of the Tk test binary |
| `fonts` | 126 | The exact X fonts of the test author |
| `nonPortable` | 88 | Depends on the machine |
| `nt` | 62 | Windows only |
| `testwrapper` | 54 | A command of the Tk test binary |
| `testsend` | 54 | A command of the Tk test binary |
| `winSend` | 51 | Windows only |
| `testtext` | 31 | A command of the Tk test binary |
| `aqua` | 29 | macOS only |
