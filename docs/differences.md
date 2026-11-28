# Differences from Tk

ztk follows the widgets of Tk 8.6.16, with some commands of Tk 8.7 and 9. A script that runs in `wish` 8.6 runs in ztk when it uses the widgets and the commands that ztk has, also on Tcl 9.1 when the script has no difference of the language (below). This page lists what a script can see that differs, what is in progress, and what ztk leaves out on purpose. It was checked against ztk `main` on 2026-11-27. The full list, with each option and each test, is [the limits file](dev/stage2-limits.md).

## Tcl and Tk releases

The `ztk` program, a program of `ztk bundle`, and the web build run a script on Tcl 9.1 by default, as the `ztcl` runner does, and report Tk 9.1.0 (`tk_version` 9.1, `package require Tk` 9.1.0, also as the package `tk`). Run a script of Tcl and Tk 8.6 with `ztk --tcl 8.6`, `ZTCL_TCL=8.6`, or `ztk bundle --tcl 8.6`: it then reports Tcl 8.6 and Tk 8.6.16. A bundled app keeps the release of its build. libztk, the drop-in libtk8.6, stays at 8.6.

The release changes the language: an integer with a leading zero is decimal, a bad byte in an encoding is an error, and the other changes of [Tcl 9.1 and Tcl 8.6](https://github.com/beetlebugorg/ztcl/blob/main/docs/tcl91.md). The widgets of ztk are the same in both releases: the widget changes of Tk 9.0 and 9.1, such as `ttk::toggleswitch`, the screen reader support, and right-to-left text, are not in ztk yet.

## Platforms

Each platform has a native backend of its own, with no toolkit library between ztk and the system.

| Platform | Window and renderer | What the system gives a script | Reference |
|---|---|---|---|
| Linux, Wayland | The Wayland client of ztk, Vulkan into dma-bufs or the CPU renderer | The clipboard, drops and drags, tray icons, file dialogs through the portal, full screen, window icons, less motion | [On Linux](linux.md) |
| Linux, X11 | The X11 client of ztk with the CPU renderer, for a desktop with no Wayland compositor | One window, the keys, the pointer, and window icons. No clipboard, no popups, and no input method yet | [On Linux](linux.md#what-works-on-x11) |
| macOS 13 and later | AppKit and Metal, with live resize | Native menus and dialogs, Core Text with SF Pro, drops and drags, tray, the Dock menu and badge, window tabs, full screen | [On macOS](macos.md) |
| Windows 10 and 11 | Win32 and Direct3D 12 | Native menus and dialogs, DirectWrite with Segoe UI Variable, the Fluent look, drops and drags, tray, taskbar, jump list, global shortcuts | [On Windows](windows.md) |
| The web | WebGPU, WebGL 2, or a 2D canvas, in WebAssembly | One window (`.`) on a canvas. A second `toplevel` has no canvas | [On the web](web.md) |
| No display | The headless backend with the CPU renderer | Screenshots and input for tests and agents | [For agents](agents.md) |

`ztk::has` tells a script which platform features this program has ([ztk::has](commands/tray.md#platform-features)).

## Missing today

| Feature of Tk | State in ztk | Issue |
|---|---|---|
| `send` | Not in ztk. | [#257](https://github.com/beetlebugorg/ztk/issues/257) |
| Event sequences of more than one event, such as `<Control-x><Control-s>` | `bind` gives an error. | [#256](https://github.com/beetlebugorg/ztk/issues/256) |
| Text peers (`text peer create`) | `peer names` gives an empty list, and `peer create` gives an error. | [#249](https://github.com/beetlebugorg/ztk/issues/249) |
| `canvas postscript` | Gives an error. | [#181](https://github.com/beetlebugorg/ztk/issues/181) |
| Rotated canvas text (`-angle`) | The option is stored, and the text renders level. | |
| Tk in a child interpreter (`load {} Tk child`) | Not in ztk. One app has one Tk. | |
| `selection` with other apps | The selection works inside the app only. The clipboard is the clipboard of the system on Windows, macOS, and Wayland, and local to the app on X11 and the web. | |
| `tk busy` | Keeps the busy mark of a window and does not block its input. | |
| `tk fontchooser` | On Windows, `show` runs the font dialog of the system to its end, then sets `-font`, calls `-command` with the font, and sends `<<TkFontchooserFontChanged>>`. On the other platforms it keeps its options and shows no dialog. | [#57](https://github.com/beetlebugorg/ztk/issues/57) |
| Bold monospace text | ztk has the regular face of JetBrains Mono only, so `{TkFixedFont 9 bold}` renders in the regular weight. | [#300](https://github.com/beetlebugorg/ztk/issues/300) |

## In progress

- Python tkinter apps on ztk, through a drop-in `libtk8.6` (libztk) with libztcl: [#223](https://github.com/beetlebugorg/ztk/issues/223).
- Grapheme clusters in the text widgets, in the renderer, and in the cell widths of the terminal: [#296](https://github.com/beetlebugorg/ztk/issues/296). Fallback faces and color emoji: [#300](https://github.com/beetlebugorg/ztk/issues/300).
- Well-known Tk apps: the Tk widget demo, tkcon, BWidget, Tablelist, tklib with Plotchart, and gitk run with no change. TkDiff and git gui are in progress ([Runs on ztk](apps.md)).

## Differences that a script can see

### Text and fonts

- The fonts come with ztk: `TkDefaultFont` is Inter and `TkFixedFont` is JetBrains Mono on Linux, the web, and headless. macOS uses SF Pro through Core Text, and Windows uses Segoe UI Variable through DirectWrite. So text widths differ from `wish`. The reason: an app has the same layout on each Linux system and in each browser.
- A font list with a named font as its family, such as `{TkFixedFont 9 bold}`, keeps the face of that named font with the new size and style, as Tk does.

### Windows

- `tk windowingsystem` gives `ztk`, so a script that tests for `x11`, `win32`, or `aqua` gets none of them. The flag `--windowingsystem NAME` of the `ztk` program gives the name that such an app needs ([Install](install.md)). libztk, the library for Python's tkinter ([Python tkinter](python-tkinter.md)), gives `x11` on Linux.
- `winfo rootx` and `rooty` of a widget in a second toplevel count from the corner of its own window on Wayland, because a Wayland program does not know the position of its windows.
- `grab -global` acts as a local grab, and `grab status` reports `global`.
- `tk_setPalette` makes the other colors from the background with its own rule: the foreground is black or white, and the active, select, and trough colors are the background 10 or 20 percent lighter or darker. The colors of `wish` differ a little.

### The look

- The theme gives the border and the padding. So `-borderwidth`, `-padx`, and `-pady` of a label, a button, and a check button default to 0. A value of the script still applies ([Styling and themes](styling.md)).
- Options for looks that the modern theme does not draw are stored and have no effect: for example `-highlightthickness`, `-activebackground`, `-overrelief`, `-troughcolor`, `-repeatdelay` of a scale, and the canvas stipples. The theme `classic` has the look of Tk on X11.
- The modern scrollbar has no arrows, so `identify` never gives `arrow1` or `arrow2`, and `fraction` and `delta` count from the ends of the trough.
- Canvas items that keep the default black of Tk render with the text color of the theme, so they stay visible in the dark scheme. `itemcget` still gives `#000000`.

### Menus

- On macOS and Windows, the `-menu` of a toplevel is the menu bar of the system, and `tk_popup` shows a menu of the system. On Wayland, a posted menu and each cascade is a popup surface that can extend past the window. On X11 and the web, ztk renders the menus inside the window ([Menus](widgets/menus.md)).
- The menu bar that ztk renders is a top inset of the toplevel, so `winfo height` of the toplevel includes the row of the bar.
- A tearoff entry shows as a line. A click on it does not tear off the menu.
- The entry options `-image`, `-bitmap`, `-compound`, `-hidemargin`, and `-columnbreak` are stored and have no effect on a menu that ztk renders.

### Styles and themes

- `ttk::style configure` and `map` change the look through CSS for `-foreground`, `-background`, `-fieldbackground`, `-bordercolor`, `-borderwidth`, `-relief`, `-padding`, `-font`, and `-indicatorcolor`. Other options are stored for `lookup`.
- `ttk::style layout` and `element create` store their data with no effect on the look, because CSS gives the look of each part ([ttk::style](styling.md#ttkstyle)).
- In `ttk::style map`, a pair with more states wins over an earlier pair with fewer states. Tk takes the earlier pair.
- The states `active` and `hover` are one flag.
- The themes `default`, `clam`, and `alt` have the modern look.

### Behavior

- A press on the trough of a scale or a scrollbar moves one step. Holding the button does not repeat.
- A `scale` runs `-command` at once after a change by the user. `wish` runs it as an idle callback.
- The list of a `ttk::combobox` is rendered by ztk in the window of the combobox, and no `$cb.popdown` toplevel or listbox exists. A combobox with no values does not open its list. `ttk::scale set` gives an empty result, where `wish` gives the result of `-command`.
- A `listbox` binds the keys of the virtual events (`<<PrevLine>>`, `<<SelectAll>>`, and the others) to `event generate`, so `bind Listbox` has more patterns than in `wish`. The rows have the height of the theme.
- `xview scroll` and `yview scroll` accept a fraction of a unit, and a scroll eases over 160 ms.
- `<MouseWheel>` and `<Shift-MouseWheel>` follow Tk 8.7. The wheel does not send `<Button-4>` and `<Button-5>`.
- `<<Paste>>` deletes the selection before it inserts, as Tk does on Windows and macOS.
- `grid` differs by one pixel from `wish` in a few layouts with overlapping spans.
- A `panedwindow` that is smaller than its panes, with no pane that can stretch, cuts the last pane at its end. Over a sash, the pointer shape changes with no change of `-cursor`.
- The row of tabs of a `ttk::notebook` has the height of the theme, so the place of a page differs from `wish`. `-image` and `-compound` of a tab are stored with no effect.

## Absent by design

- No code of Tk and no Xlib: ztk is a new implementation. The behavior follows the manual pages of Tk and the results of `wish` 8.6.16 ([References](references/README.md)). Its X11 client is only a backend for a window.
- No global grab: `grab -global` stays local, so an app cannot take the input of other apps.

## Additions

ztk adds these commands and options. [The ztk:: commands](commands/README.md) lists the reference page of each.

- `ztk::terminal`, a terminal widget on libghostty-vt, with `-shell` for the shell of ztcl ([Terminal](widgets/terminal.md)).
- `ztk::style`, `ztk::class`, and `ztk::animate`: CSS styles, style classes, and animation ([Styling and themes](styling.md), [Animation](animation.md)).
- `ztk::tooltip`, `ztk::limit`, and `ztk::clock` ([ztk::limit](commands/limit.md)).
- `ztk::snapshot`, `ztk::tree`, and `ztk::inject` for tests and agents ([For agents](agents.md)), and `ztk::debug` with the Inspect panel and its Probe tab on the site ([Debugging](debugging.md)).
- The platform commands: `ztk::dnd`, `ztk::tray`, `ztk::taskbar`, `ztk::recent`, `ztk::hotkey`, `ztk::win::*`, and `ztk::mac::*`.
- `image create photo -density 2`: a photo made for a screen of scale 2. A widget lays it out at its logical size and renders its pixels 1:1 on such a screen.
- `wm iconphoto` sets the window icon on each desktop platform, and the Dock icon on macOS.
- The style classes `switch`, `segmented`, and `search`, `-placeholder` on entries, undo in entries, and fractional wheel steps.
- Text widgets move, delete, and wrap by grapheme cluster (UAX #29), where Tk 8.6 steps by character. The text index unit `graphemes` is a ztk addition.
