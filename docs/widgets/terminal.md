# Terminal

## ztk::terminal

`ztk::terminal` is a terminal emulator widget. This one runs the shell of ztcl: click it, type `pu`, and press Tab. Up and Down go through the history.

<!-- widget: terminal; shot: update idletasks; .t send "lsort {pear apple fig}\r"; .t send "string toupper hello\r"; update -->
```tcl
ztk::terminal .t -shell 1 -width 60 -height 14
pack .t -fill both -expand 1
focus .t
```

| Option or command | What it does |
|---|---|
| `-shell 1` | Runs the shell of `ztcl` in the interpreter of the widget: Tab completion, history, colors. |
| `-command list` | Runs a program on a pseudo-terminal, for example `-command {/bin/sh -l}`. It needs `exec`. |
| `-inputcommand script` | Gets the keys and the replies when no program runs. |
| `-width`, `-height` | The size in cells. |
| `-font` | The font of the cells. The default is TkFixedFont, a monospace face. |
| `-scrollback n` | The lines of the scrollback (default 10,000). |
| `write`, `send`, `paste` | Put text and sequences on the screen, or send bytes to the program. |
| `get`, `size`, `cursor`, `title` | Read the screen. |
| `selection`, `copy`, `yview` | Select, copy, and scroll. |

### Write your own output

Without a program, `write` puts text and escape sequences on the screen, and `-inputcommand` gets the keys. This snippet echoes what you type.

<!-- live -->
```tcl
ztk::terminal .t -width 40 -height 12 -inputcommand echo
pack .t -fill both -expand 1
proc echo {data} {.t write [string map [list \r \r\n] $data]}
.t write "\x1b\[1;32m$\x1b\[0m echo hello\r\nhello\r\n"
.t write "\x1b\[1;34mblue\x1b\[0m \x1b\[7minverse\x1b\[0m \x1b\[4munderline\x1b\[0m\r\n"
.t write "╭────╮\r\n│ ok │\r\n╰────╯\r\n$ "
focus .t
```

<!-- more: The core and the speed -->

`ztk::terminal` is a terminal emulator. Its state (the parser, the screen, the scrollback, the cursor, and the modes) is [libghostty-vt](https://github.com/ghostty-org/ghostty) 1.0.2, the terminal core of Ghostty, through the `ztcl::vt` module of ztcl. The build compiles it from source and links it statically on each target, with no C code, no C++ code, and no libc. ztk renders the cells with its own fonts and colors, so each renderer draws the terminal, and ztk handles the keys, the mouse, and the selection. Tk has no terminal widget.

On 2026-11-26, `zig build term-bench` (ReleaseFast, 8,388,627 bytes of generated output on 80 by 24 cells, x86-64 Linux) parsed 141.6 MiB/s with libghostty-vt, against 114.7 MiB/s with the earlier VT core of ztk. libghostty-vt and `ztcl::vt` add 595,823 bytes to `ztk.wasm` (`docs/dev/libghostty.md`). The widget keeps no combining marks, and a resize cuts long lines and does not wrap them again. The design is in `docs/dev/terminal.md`, and [the references](../references/terminal.md) credit Ghostty.

<!-- end more -->

<!-- more: Platforms -->

| Platform | `-shell 1` | `-command` (a program on a PTY) |
|---|---|---|
| Linux, x86-64 and arm64 | Yes | Yes, on a pseudo-terminal of `ztcl::pty`, when the embedder turns on `exec` |
| macOS, arm64 and x86-64 | Yes | Yes, as on Linux |
| Windows, x86-64 | Yes | Yes, on a pseudo console (ConPTY) |
| The web (WebAssembly) | Yes | No: the browser build has no processes |

<!-- end more -->

<!-- more: All the details -->

- `-command list` runs a program on a pseudo-terminal with `ztcl::pty spawn`, for example `-command {/bin/sh -l}` or `-command {vim notes.txt}`. The interpreter needs the `exec` capability of ztcl. The `ztk` program does not turn it on, so in `ztk` and in the playground `-command` gives an error. An embedder that turns on `exec` and `channels` gets a full terminal. `-cwd dir` is the working folder of the program, and `-exitcommand script` runs with the status of `ztcl::pty status` when the program ends. On Windows the program runs on a pseudo console (ConPTY), for example `-command cmd.exe` or `-command {powershell.exe -NoLogo}`, and its output has the escape sequences of a VT terminal.
- Without a program, `pathName write data` puts text and control sequences on the screen, and the keys and the replies of the terminal go to the script of `-inputcommand`, with the bytes as the last word.
- `-shell 1` runs the interactive shell of the `ztcl` program in the interpreter of the widget, with no program and no PTY. It is the same line editor as in a terminal: Tab completes commands, subcommands, variables, and the file names when the interpreter has `file`. Up and Down go through the history, `shell mode vi` turns on vim keys, and the code has colors. The output of `puts` goes to the screen. The shell has the capabilities and the compute limit of the interpreter, so in `ztk` and in the playground it has no files, network, or clock. Ctrl-D on an empty line starts a new prompt. The editor key (Ctrl-X Ctrl-E) gives the line back with no change, because the widget has no editor.
- `-width` and `-height` are the size in cells. After the layout, the size of the grid follows the size of the widget, and the program gets the new size.
- The terminal understands the sequences of xterm that shells and full-screen programs use: the cursor moves, the erase and insert functions, the scroll region, SGR with 16, 256, and 24-bit colors, bold, italic, underline, inverse, and strike, the alternate screen, the DEC line drawing set, wide characters, bracketed paste, the mouse reports (X10, normal, button, and any-motion, in the SGR form or the X10 form), the focus reports, the window title, and the replies to the status queries and the color queries.
- The box drawing characters and the block elements are rendered as boxes, so their lines meet with each font.
- `-scrollback n` keeps n lines (default 10,000). The wheel and Shift with Prior or Next scroll the view, and `yview` works as for a listbox.
- A drag with button 1 selects text, a double click selects a word, and a triple click selects a line. Control-Shift-C copies the selection and Control-Shift-V pastes. When the program asks for mouse reports, hold Shift to select.
- Subcommands: `write`, `send`, `paste`, `get ?first? ?last?` (the text of view lines, where 0 is the first row of the screen and negative lines are in the scrollback), `size`, `cursor`, `title`, `selection get|clear|range`, `copy`, `yview`, `channel`, `status`, and `kill ?signal?`.
- The part `::selection` accepts CSS rules. The class `Terminal` gets its colors from the theme.

<!-- end more -->
