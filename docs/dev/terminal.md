# The terminal widget

`ztk::terminal` is a terminal emulator widget for dockyard and for each app that shows the output of a program. The user page is `docs/widgets/terminal.md`.

## The VT core

The state of the terminal is libghostty-vt 1.0.2, through `ztcl.vt.Term` of ztcl (module `ztcl::vt`). `src/term/core.zig` gives the widget the fields and the methods that it used on the earlier `Screen`. The user approved the dependency on 2026-11-26. ztk gets the module through its dependency on ztcl, which builds it from source with `-Dsimd=false` and links it statically, so the module has no C code, no C++ code, and no libc. `docs/dev/libghostty.md` has the pin, the measurements, and the size.

ztk keeps its own code for the keys (`keys.zig`), the box drawing characters (`boxdraw.zig`), and the widget (`widget.zig`): the rendering, the mouse reports, the selection, and the scroll of the view. The earlier VT core of ztk (`parser.zig`, `screen.zig`, `width.zig`) is gone.

## The pseudo-terminal

ztcl has the PTY (`ztcl::pty`, ztcl `docs/dev/pty.md`). The widget runs `ztcl::pty spawn` in its interpreter, so a program starts only when the embedder turned on `exec`. The ztk library and the `ztk` program turn on no capability. The widget reads the descriptor of the channel from a native timer of the loop, because the loop of ztk has no wait on a descriptor yet. A wait on descriptors in the loop of each backend is a later change.

## Limits

- No combining marks, no reflow on resize, no hyperlinks (OSC 8), no Kitty keyboard protocol, no images.
- The headless backend has only the Inter font, so the shots use a proportional font in a grid of cells.
- `ztcl::pty` runs on Linux, macOS, and Windows. On Windows the widget reads the output pipe and writes the input pipe of the pseudo console, and asks `ztcl::pty status` when the output is quiet, because the output pipe stays open after the program ends.
