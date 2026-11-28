# Changelog

## v1.0.0-beta.1 (2026-11-28)

The first beta of ztk 1.0. ztk adds native clients for Wayland and X11 with no C library, the native look of each platform, drag and drop, the tray, the taskbar, and the jump lists, `ztk bundle --target` for each platform from any host, the `ttk` widgets, the canvas, `ztk::debug` and `ztk --mcp` for agents, and the WebGPU renderer of the web build. ztk follows Tcl 9.1 by default (the breaking change below).

- **Breaking:** ztk follows Tcl and Tk 9.1 by default: the `ztk` program, the programs of `ztk bundle`, and the web build. Tk reports 9.1.0. A script of 8.6 can break on the differences of the language: an integer with a leading zero is decimal, a bad byte in an encoding is an error, and the other changes of [Tcl 9.1 and Tcl 8.6](https://github.com/beetlebugorg/ztcl/blob/main/docs/tcl91.md). Run such a script with `ztk --tcl 8.6`, `ZTCL_TCL=8.6`, or `ztk bundle --tcl 8.6`. The widgets are the same in both releases, and the widget changes of Tk 9.0 and 9.1 are not in ztk yet. libztk, the drop-in libtk8.6, stays at 8.6. See [Differences from Tk](docs/differences.md).
- Adds the Wayland client of ztk, with no C library: the wire protocol, the XKB key map, the pointer shapes, the clipboard, and the input method. The static Linux programs of a release open a window. The main window renders with Vulkan into dma-bufs, or with the CPU renderer. See [On Linux](docs/linux.md).
- Adds an X11 client for a Linux desktop with no Wayland compositor.
- Adds drops of files and text from other apps (`tkdnd::drop_target`) and drags to them (`ztk::dnd drag`) on Windows, macOS, and Wayland. See [ztk::dnd](docs/commands/dnd.md).
- Adds `ztk::tray` on Windows, macOS, and Linux (StatusNotifierItem), and `ztk::has`. See [ztk::tray](docs/commands/tray.md).
- Adds `ztk::taskbar` (Windows and macOS), `ztk::recent`, and `ztk::hotkey` (Windows). See [ztk::taskbar](docs/commands/taskbar.md).
- Adds `ztk::win::backdrop`, `ztk::win::jumplist`, and `ztk::win::thumbbar`, and `ztk::mac::dockmenu` and `ztk::mac::tabbing`. See [ztk::win](docs/commands/win.md) and [On macOS](docs/macos.md).
- Adds the native look of each platform: Core Text with SF Pro, the native message box, color dialog, and file dialogs on macOS; DirectWrite with Segoe UI Variable, the Fluent controls of WinUI 3, the title bar in the scheme of the app, and the native dialogs on Windows; the `FileChooser` portal on Linux.
- Adds `wm attributes -fullscreen` and `-topmost`, and follows the less-motion setting of the system, on macOS, Windows, and Wayland.
- Adds `ztk bundle --target` for each platform from any host: a signed macOS app folder with `-o Name.app`, a Windows program with its icon, manifest, and version info, and a Linux program with a desktop entry. `ZTK_HEADLESS=1` runs a bundled app with no display.
- Runs famous Tk apps on ztk, and adds the option database: `option add`, `clear`, `get`, and `readfile`. See [Runs on ztk](docs/apps.md).
- Moves `ztk::terminal` to libghostty-vt through `ztcl::vt`, and adds `-shell` for the shell of ztcl. Runs the program of the terminal on the pseudo console of Windows.
- Adds the reference pages of the `ztk::` commands in `docs/commands/`.
- Adds builds for aarch64-windows, and an Arch Linux PKGBUILD in `packaging/arch/ztk-git`.
- Adds `zig build runtimes`: the `ztk` program of each target of `ztk bundle --target`, with the full GUI backend of its platform, in `zig-out/lib/ztk/runtime/`. The release programs for Linux now have the Vulkan renderer.
- `wm iconphoto` sets the window icon on Linux: `_NET_WM_ICON` on X11, and `xdg-toplevel-icon-v1` on Wayland.
- Adds `ztk::debug sources`, `ztk::debug why`, and `ztk::debug geometry`: the source of each option of a widget and its geometry chain.
- Adds `ztk::debug trace`: records of events, bindings, commands, option writes, geometry passes, dirty widgets, frames, focus, and grabs, with filters.
- Adds `ztk::debug mark` and `ztk::debug diff`: the pixels and the widgets that changed between two captures.
- Adds `ztk::debug explain`, `click`, `type`, `ran`, `changes`, and `tree`, short answers for agents, and `ztk --mcp`, which serves them as MCP tools.
- Adds the page "Debug a form": a live form with three bugs to find with `ztk::debug`, and the Console of the live snippets.
- The Inspect panel of the live snippets has tabs: the options with the source of each value, the bindings, the geometry chain, the scripts and procs, and the trace of the widget. A change of an option goes into the line of the code that set it.
- The Inspect panel has a Probe tab: probes and breakpoints on the lines of the procs behind a widget (`ztcl::probe`), and their records. A breakpoint stops the frames of the snippet until Continue.
- `ztk::debug why` gives `fileline`, the line of a command in its file, also inside a proc. A change of an option in the Inspect panel then goes into the line in the proc.
- Adds the `ttk` widgets `ttk::button`, `ttk::checkbutton`, `ttk::radiobutton`, `ttk::label`, `ttk::frame`, `ttk::labelframe`, `ttk::entry`, `ttk::separator`, and `ttk::sizegrip`, the command `ttk::style`, and the `classic` theme.
- Adds `spinbox`, entry validation, `-placeholder`, the search field, undo, and the `clipboard` command.
- Adds the `canvas` widget with all item types, scrolling, `image create photo`, and item animation.
- Adds `scrollbar`, the scroll protocol, and the mouse wheel.
- Moves keyframes, color animations, the parts of widgets, and drags to the render thread.
- Adds the examples `themes.tcl`, `themes-classic.tcl`, and `counter.tcl`.
- Adds the example apps `examples/spreadsheet.tcl` (10 000 rows on a canvas, with formulas) and `examples/vector.tcl` (a drawing tool with SVG export and a script console), their tests in `tests/apps.sh`, their bench cases, and their live cards on the site.
- Adds `ztk::limit`, the `interp` command, and `ztk::style scheme`.
- Adds the WebGPU renderer of the web build (`webgpu.js`). `"auto"` selects WebGPU, then WebGL 2, then the CPU renderer. The web canvas has the size of its window at each pixel ratio.

## v0.2.0-beta (2026-11-25)

- Adds `pack`, `place`, `checkbutton`, `radiobutton`, `toplevel`, `labelframe`, `message`, `grab`, `ztk::tooltip`, and `scale`.
- Adds CSS transitions, `@keyframes`, `ztk::animate`, and the frame clock.
- Adds the web backend with WebGL 2, and the live examples on the site.
- Adds the plan, the Stage 1 tasks, the review checklist, and the references.
- Adds the tools that measure the size of Tk.
- Adds the docs site, the CI and release workflows, and the Homebrew formula template.
- Licensed under BSD-2-Clause.
- Adds the npm package `@beetlebug/ztk`, with types, and a workflow that publishes it on a version tag. `ztk.js` has `mount`, a CPU renderer for a browser with no WebGL 2, and `destroy`. See `docs/web.md` and `docs/dev/npm.md`.

