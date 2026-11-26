# Differences from Tk

ztk follows Tk 8.6.16. A script that runs in `wish` 8.6 runs in ztk when it uses the widgets that ztk has. This page lists the differences that a script can see. The full list, with each option and each test, is [the limits file](dev/stage2-limits.md).

## Missing today

- Widgets: the dialogs (`tk_getOpenFile`, `tk_messageBox`, and the others) and `ttk::treeview`. The `text` widget has no embedded windows, embedded images, or peers yet.
- Commands: `option`, `selection`, `event add`, `send`, and `package`. The Tk test files cannot run, because `tcltest` needs `package`.
- The clipboard is local to the app. It is not connected to the clipboard of the system.
- `canvas postscript`.
- Fonts come from ztk (Inter by default), so text widths differ from `wish`.

## Platforms

- Linux: a Wayland window with the CPU renderer, a headless backend, and a direct backend for the framebuffer. The Vulkan renderer works offscreen only.
- macOS and Windows: the headless backend only. The native backends are planned.
- The web: one window (`.`) on a canvas. A second `toplevel` has no canvas.
- `tk windowingsystem` gives `ztk`, so a script that tests for `x11`, `win32`, or `aqua` gets none of them.

## The look

- The theme gives the border and the padding. So `-borderwidth`, `-padx`, and `-pady` of a label, a button, and a check button default to 0. A value of the script still applies.
- Options for looks that the modern theme does not draw are stored and have no effect: for example `-highlightthickness`, `-activebackground`, `-overrelief`, `-troughcolor`, `-repeatdelay` of a scale, and the canvas stipples.
- The modern scrollbar has no arrows, so `identify` never gives `arrow1` or `arrow2`, and `fraction` and `delta` count from the ends of the trough.
- Canvas items that keep the default black of Tk draw with the text color of the theme. `itemcget` still gives `#000000`.
- A canvas text item does not rotate with `-angle`.

## Menus

- On Linux and the web, the menus are drawn inside the window for now. A menu cannot extend past the edges of the window. The popup surfaces of Wayland and the web are planned.
- The drawn menu bar is a top inset of the toplevel, so `winfo height` of the toplevel includes the row of the bar.
- The coordinates of `post` and `tk_popup` are those of the window of the toplevel of the menu, as `%X` and `%Y` give them.
- A tearoff entry shows as a line. A click on it does not tear off the menu.
- The entry `-image`, `-bitmap`, `-compound`, `-hidemargin`, and `-columnbreak` are stored and have no effect on a drawn menu.
- The modern theme draws a chevron on each menu button, also with `-indicatoron 0`.

## Styles and themes

- `ttk::style configure` and `map` change the look through CSS for `-foreground`, `-background`, `-fieldbackground`, `-bordercolor`, `-borderwidth`, `-relief`, `-padding`, `-font`, and `-indicatorcolor`. Other options are stored for `lookup`.
- `ttk::style layout` and `element create` store their data with no effect on the look.
- In `ttk::style map`, a pair with more states wins over an earlier pair with fewer states. Tk takes the earlier pair.
- The states `active` and `hover` are one flag.
- The themes `default`, `clam`, and `alt` have the modern look.

## Behavior

- `grab -global` acts as a local grab, and `grab status` reports `global`.
- A press on the trough of a scale or a scrollbar moves one step. Holding the button does not repeat.
- A `scale` runs `-command` at once after a change by the user. `wish` runs it as an idle callback.
- The list of a `ttk::combobox` is drawn by ztk in the window of the combobox, and no `$cb.popdown` toplevel or listbox exists. A combobox with no values does not open its list. `ttk::scale set` gives an empty result, where `wish` gives the result of `-command`. `ttk::progressbar start` runs `step` with `after`, as in `wish`, and the indeterminate bar moves on its own while the timer runs.
- A `listbox` binds the keys of the virtual events (`<<PrevLine>>`, `<<SelectAll>>`, and the others) to `event generate`, so `bind Listbox` has more patterns than in `wish`. The rows have the height of the theme, and a drag above or below the rows scrolls one row for each motion event.
- `xview scroll` and `yview scroll` accept a fraction of a unit, and a scroll eases over 160 ms.
- `<MouseWheel>` and `<Shift-MouseWheel>` follow Tk 8.7. The wheel does not send `<Button-4>` and `<Button-5>`.
- `<<Paste>>` deletes the selection before it inserts, as Tk does on Windows and macOS.
- `grid` differs by one pixel from `wish` in a few layouts with overlapping spans.
- A `panedwindow` that is smaller than its panes, with no pane that can stretch, cuts the last pane at its end. Over a sash, the pointer shape changes with no change of `-cursor`.
- The row of tabs of a `ttk::notebook` has the height of the theme, so the place of a page differs from `wish`. `-image` and `-compound` of a tab are stored with no effect.

## Additions

ztk adds `ztk::terminal` (a terminal emulator widget), `ztk::style`, `ztk::class`, `ztk::animate`, `ztk::tooltip`, `ztk::limit`, `ztk::snapshot` (a PNG image of a widget as base64 text), `ztk::tree` (each widget below a path with its class, its position in the toplevel, its size, and its map state), `ztk::inject` (pointer, wheel, key, and text events that go through the hit test, the hover state, and the focus, as the events of a backend do), the style classes `switch`, `segmented`, and `search`, `-placeholder` on entries, undo in entries, and fractional wheel steps.
