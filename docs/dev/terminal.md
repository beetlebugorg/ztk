# The terminal widget

`ztk::terminal` is a terminal emulator widget for dockyard and for each app that shows the output of a program. The user page is `docs/widgets/terminal.md`.

## The VT core: libghostty or a parser in Zig

The first plan was to embed the terminal state of libghostty-vt and draw the grid in ztk. On 2026-11-25 the facts were:

- libghostty-vt has releases (`vt-1.0.0` to `vt-1.0.2`), a C API with semantic versions and an ABI check in its CI, and the MIT license.
- Each release needs one Zig version. libghostty-vt 1.0 needs Zig 0.17, and ztk uses Zig 0.16.
- The build fetches Zig packages, and its fast path uses simdutf and Highway in C++. Section 6 of `plan.md` allows no third-party library.

So ztk has its own VT core in `src/term/`: `parser.zig` (the state machine), `screen.zig` (the grids, the cursor, the modes, the scrollback), `width.zig` (the cell width of a code point), `keys.zig` (the bytes of a key), and `boxdraw.zig`. The widget in `widget.zig` uses the screen through `write`, `resize`, `lineAt`, `scrollbackLen`, the cursor, and the modes. A second form of that interface on libghostty-vt is possible when ztk moves to Zig 0.17 and the user approves the dependency.

## The pseudo-terminal

ztcl has the PTY (`ztcl::pty`, ztcl `docs/dev/pty.md`). The widget runs `ztcl::pty spawn` in its interpreter, so a program starts only when the embedder turned on `exec`. The ztk library and the `ztk` program turn on no capability. The widget reads the descriptor of the channel from a native timer of the loop, because the loop of ztk has no wait on a descriptor yet. A wait on descriptors in the loop of each backend is a later change.

## Limits

- No combining marks, no reflow on resize, no hyperlinks (OSC 8), no Kitty keyboard protocol, no images.
- The headless backend has only the Inter font, so the shots use a proportional font in a grid of cells.
- `ztcl::pty` runs on Linux, macOS, and Windows. On Windows the widget reads the output pipe and writes the input pipe of the pseudo console, and asks `ztcl::pty status` when the output is quiet, because the output pipe stays open after the program ends.
