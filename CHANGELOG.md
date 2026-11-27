# Changelog

## Unreleased

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

