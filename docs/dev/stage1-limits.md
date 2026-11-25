# Limits of Stage 1

This page lists what a Stage 1 widget, command, or part does not have, compared with `wish` 8.6.16. Each task adds its entries.

## Text (task 07)

- The font engine reads TrueType outlines (`glyf`) and the `kern` pair adjustment of GPOS. It does not read CFF outlines, variable fonts, color glyphs, or font collections. A font of these kinds gives `error.Unsupported`.
- The package has two faces: Inter Regular and Inter Bold. A weight of 600 or more selects Bold. Each other weight selects Regular. Each family name, and `monospace`, selects one of the two. Italic has no face, so italic text draws upright. The fonts of the system come in Stage 2.
- Text has no ligatures, no combining marks, no right-to-left text, no font fallback, and no line breaks.
- `underline` and `overstrike` in a font value are accepted and ignored.
- The atlas has one page of 1024 by 1024 texels. A full page gives `error.AtlasFull`.
- A glyph has no hinting and no subpixel (LCD) rendering.
- A font size is at most 1024 logical pixels. A larger size gets 1024. A glyph that does not fit in the atlas is left out of the frame.
- A cmap format 12 glyph id above 65535 gives glyph 0. Point matching in a composite glyph counts the four phantom points. The file has no `vmtx` reader, so the top and bottom phantom points are the ascent and the descent of `hhea`.

## Widget tree (tasks 02 and 03)

- `rename ztk::priv::app {}` no longer breaks the program: the App is in the `user` field of the interpreter.
- A widget path with an empty name part (`.a.` or `..b`) gives `bad window path name`. `wish` accepts these paths.
- `frame` has the options `-background`, `-bg`, `-borderwidth`, `-bd`, `-class`, `-cursor`, `-height`, `-padx`, `-pady`, `-relief`, `-takefocus`, and `-width`. `wish` also has `-colormap`, `-container`, `-highlightbackground`, `-highlightcolor`, `-highlightthickness`, and `-visual`.
- A widget command accepts only `cget` and `configure`, with a prefix of at least two letters.
- A widget tree of more than 32 levels (counting `.`) draws no frame. The scene builder has 64 slots for clips and each widget uses two. `zig-out/bin/ztk --headless` with 30 nested frames that each have a label draws, and 31 gives `frame failed: NestingTooDeep` (2026-11-23).
- A window is at most 8192 logical pixels on each side, and a frame at most 16384 device pixels. A larger request gets the limit. A size, a position, or a pixel option in a script, or a length in a style sheet, is at most 2^24 pixels. A larger value gives 2^24. The sum of the lines of one grid axis is also at most 2^24, so a layout that needs more has its last lines cut.
- A deleted widget stays in memory until the outermost command or callback ends. `winfo exists` is false at once. A long script that stays inside one command or callback keeps this memory until it returns.
- During its Destroy binding, a widget answers as in `wish`: `winfo exists` gives 0, the widget command is gone, a new child gives `can't create window: parent has been destroyed`, and `event generate` and `focus` have no effect. `grid` of a widget in this state gives `bad window path name`, and `wish` gives `can't determine master window`.
- `destroy` removes the bindings of the widget path and each command key of the widget, also after `rename` and `namespace import`. The key of the path goes at once. Another key goes when the outermost command or callback ends, and until then its call gives `invalid command name`. `rename .f {}` removes the command and keeps the widget (Tk deletes the widget).
- Each widget that a program makes keeps one small command handle (16 bytes on x86-64) until the App ends. A program that makes and deletes widgets forever grows by this amount for each widget.
- Only `.` exists as a toplevel.

## Platforms

- The default backends depend on the target. Linux has Wayland, direct, and headless, with Vulkan. macOS and Windows have headless only, with no Vulkan.
- CI runs the tests on Linux only, because the tests use pipes, signals, and other Linux interfaces. CI compiles and links the program for x86-64 and ARM Linux (musl), x86-64 and ARM macOS, and x86-64 Windows. No run on macOS or Windows has checked the program (2026-11-23).

## Variable links

- In the pinned ztcl, `trace add variable` on a name that `upvar` links to an array element replaces the link. A later write reaches the trace and no longer reaches the element. So `upvar #0 a(k) e; vwait e` ends, and `a(k)` keeps its old value, where `wish` writes it. `-textvariable e` has the same limit. ztk cannot repair this from outside ztcl.
- A script trace on such a link stops the compact.

## Performance targets not met so far

- Task 06: `cpu-speed` (10 000 boxes in 1920x1080) measured 198 and 200 ms in `ReleaseFast` on 2026-11-23 on a machine with a load average of 12 to 14 (command: `zig build test -Doptimize=ReleaseFast -Dtest-filter=cpu-speed`). The limit is under 200 ms, so it is met only by a small margin.
- Task 09: `style-speed` was 29.9 ms before the cache of matching rules. It measures 0.24 and 0.27 ms for 1 001 widgets in `ReleaseFast` on 2026-11-23 (command: `zig build test -Doptimize=ReleaseFast -Dtest-filter=style-speed`, same loaded machine). The limit of 3 ms is met, and the test asserts it in `ReleaseFast`.

## grid (task 10)

- `grid` has the commands of `wish` 8.6.16 for a container that holds frames. It does not have `grid configure -in` for a container in another toplevel, because Stage 1 has one toplevel.
- Three or more spans that overlap on empty lines, and a weighted line at its minimum in a container that is too small, can differ by one pixel from `wish`. See `docs/dev/tasks/BLOCKED.md`.
- `grid size` counts a configured line only when one of its options is not the default. Tk has the same result for the cases that were checked, and no other case was checked.
- `grid location` of a point outside the layout, and `grid bbox` with a column or a row outside the layout, were not compared with `wish`.
- The oracle result: seeds 1, 2, 99, 5, and 6 gave 2 to 5 different layouts of 200 (command: `tools/oracle.sh tools/oracle-grid.tcl <seed> 200`, 2026-11-23).

## label, wm, tk, and winfo (task 11)

- `label` has the options `-anchor`, `-background`, `-bd`, `-bg`, `-borderwidth`, `-cursor`, `-fg`, `-font`, `-foreground`, `-height`, `-justify`, `-padx`, `-pady`, `-relief`, `-state`, `-takefocus`, `-text`, `-textvariable`, and `-width`. `wish` also has `-activebackground`, `-activeforeground`, `-bitmap`, `-compound`, `-disabledforeground`, `-highlightbackground`, `-highlightcolor`, `-highlightthickness`, `-image`, `-underline`, and `-wraplength`. Each of these gives `unknown option`.
- The default `-padx` and `-pady` of a label are 0 (1 in `wish`). The theme sets the padding.
- `wm` handles `title`, `geometry`, `minsize`, `maxsize`, `resizable`, `protocol` (only `WM_DELETE_WINDOW` has an effect), `withdraw`, `deiconify`, and `state` (`normal` and `withdrawn`). Each other subcommand gives `wm <name> is not supported in this stage`. The position in `wm geometry` is read and ignored. `wm maxsize` has the default `10000 10000`.
- `tk` handles `scaling` and `windowingsystem`. `tk windowingsystem` gives `ztk`: a script that tests for `x11`, `win32`, or `aqua` gets none of them.
- `winfo` handles `children`, `class`, `exists`, `geometry`, `height`, `ismapped`, `manager`, `name`, `parent`, `reqheight`, `reqwidth`, `rootx`, `rooty`, `toplevel`, `viewable`, `width`, `x`, and `y`.
- The window takes the size of the content of `.` when a geometry manager has content in `.` and `wm geometry` has no size. Otherwise the window keeps the size that the backend gave.

## bind, bindtags, and event (task 12)

- A pattern is one event. A sequence such as `<Control-x><Control-s>` gives `event sequences are not supported in this stage`. A plain string of more than one character is also a sequence.
- `Meta` and `M` are the same as `Alt` and `Mod1`. `wish` on X11 can map `Meta` to another modifier.
- `bind` has the event types `ButtonPress`, `ButtonRelease`, `Motion`, `Enter`, `Leave`, `KeyPress`, `KeyRelease`, `FocusIn`, `FocusOut`, `Configure`, `Destroy`, `Map`, `Unmap`, and virtual events. A virtual event runs only from `event generate`.
- `event add`, `event delete`, and `event info` give `event <name> is not supported in this stage`.
- `event generate` has the options `-x`, `-y`, `-rootx`, `-rooty`, `-button`, `-keysym`, `-keycode`, `-state`, `-time`, `-data`, `-width`, `-height`, and `-when now`. Each other option of `wish` gives `event generate option "<name>" is not supported in this stage`.
- A key event goes to the toplevel in this stage. A key event that `event generate` makes goes to the widget that the command names, at once, as the task asks. `wish` sends the key event to the focus widget.
- A field `%f`, `%a`, `%c`, `%D`, `%E`, `%m`, `%N`, `%o`, `%P`, `%R`, `%S`, and `%Z` is not substituted. The percent sign goes away and the letter stays.
- `Enter` and `Leave` go to the widget under the pointer only, with no detail field and none for the ancestors.
- The order of the patterns in `bind tag` is the newest first, the same as `wish` for the cases that were checked on 2026-11-23.

## focus and button (tasks 13 and 14)

- `focus` has `-displayof`, `-force`, and `-lastfor`. `-force` is the same as `focus path`, because a program cannot take the keyboard from another program in Stage 1. `focus` of an empty string does nothing.
- Traversal with `Tab` and `Shift-Tab` uses bindings on the tag `all`, not the virtual events `<<NextWindow>>` and `<<PrevWindow>>`. `bind all` lists three key bindings and not the four of `wish`.
- A script value of `-takefocus` counts as an empty value.
- `button` has the options `-activebackground`, `-activeforeground`, `-anchor`, `-background`, `-bd`, `-bg`, `-borderwidth`, `-command`, `-cursor`, `-disabledforeground`, `-fg`, `-font`, `-foreground`, `-height`, `-justify`, `-padx`, `-pady`, `-relief`, `-state`, `-takefocus`, `-text`, `-textvariable`, and `-width`. `wish` also has `-bitmap`, `-compound`, `-default`, `-highlightbackground`, `-highlightcolor`, `-highlightthickness`, `-image`, `-overrelief`, `-repeatdelay`, `-repeatinterval`, `-underline`, and `-wraplength`. Each of these gives `unknown option`.
- `button` has the subcommands `cget`, `configure`, and `invoke`. `flash` gives `flash is not supported in this stage`.
- A button re-arms when the pointer comes back with button 1 still down. `wish` has the same result through `<Enter>` with the button state.

## entry (task 15)

- `-textvariable` of `label`, `button`, and `entry` reads the variable in the global namespace, as Tk does, whatever the caller is.
- `entry` has the options `-background`, `-bd`, `-bg`, `-borderwidth`, `-cursor`, `-exportselection` (stored, no effect), `-fg`, `-font`, `-foreground`, `-insertofftime`, `-insertontime`, `-insertwidth`, `-justify` (only `left` has an effect), `-relief`, `-selectbackground`, `-selectforeground`, `-show`, `-state`, `-takefocus`, `-textvariable`, and `-width`. `wish` also has `-disabledbackground`, `-disabledforeground`, `-highlightbackground`, `-highlightcolor`, `-highlightthickness`, `-insertbackground`, `-insertborderwidth`, `-invalidcommand`, `-readonlybackground`, `-validate`, `-validatecommand`, and `-xscrollcommand`. Each of these gives `unknown option`. The short names `-invcmd`, `-vcmd`, and `-selectborderwidth` of `wish` are not options either, and `-invalidcommand` and `-validatecommand` are the full names of the first two.
- The widget subcommands are `cget`, `configure`, `delete`, `get`, `icursor`, `index`, `insert`, and `selection` (`clear`, `present`, `range`). `bbox`, `scan`, `validate`, and `xview` give `<name> is not supported in this stage`. `selection adjust`, `from`, and `to` give `selection <word> is not supported in this stage`.
- The caret color comes from the style (`caret-color`), not from `-insertbackground`.
- A word is a run of letters, digits, `_`, and each character above U+007F. Word and character rules follow UAX #29 in Stage 4.
- The clipboard, the primary selection, undo, and input methods are Stage 2 or later. A key with `%A` of a control character inserts nothing.
- The entry does not read the virtual events `<<PrevChar>>`, `<<SelectAll>>`, and the others. The class bindings use key patterns.

## The Vulkan renderer (task 16)

- The renderer draws to an offscreen image. It has no surface and no swapchain until task 17.
- The atlas is one page of 1024 by 1024 texels. A draw waits for the queue, so the CPU does not overlap with the GPU.
- Measured on 2026-11-23 on the development machine, one draw of 10 000 boxes of 100 by 60 pixels with alpha in 1920 by 1080 (command: `ZTK_GPU=<n> zig build test -Doptimize=ReleaseFast -Dtest-filter=vulkan-speed`): 26.7 ms on the Intel HD Graphics 530 and 1.8 ms on the NVIDIA GeForce RTX 4070. The limit of 2 ms is met on the NVIDIA device and not met on the Intel device. The boxes overlap, so each pixel runs the box math about 5 to 10 times on this scene.
- `lavapipe` is not installed. A machine with no Vulkan device skips the Vulkan tests with the message `SKIP: no Vulkan device`.

## The Wayland backend and the ztk program (task 17)

- The window draws with the CPU renderer into a `wl_shm` buffer. The Vulkan swapchain is not done (see `docs/dev/tasks/BLOCKED.md`). The flag `--cpu` has no other effect.
- Server-side decorations come from the protocol `xdg-decoration`. A compositor without it shows no title bar. The private compositor of the tests has the protocol, and sway draws a title bar.
- The cursor shape comes from the protocol `cursor-shape-v1` when the compositor has it. Otherwise the cursor is the one the compositor shows.
- The scale comes from `fractional-scale-v1` with `viewporter`, or from the integer scale of `wl_surface.preferred_buffer_scale` (compositor version 6). A compositor with neither gives the scale 1.
- `requestSize` changes the logical size at once and gives a `resize` event. A tiling compositor gives its own size in the next `configure`, and that size wins.
- Key repeat runs in the backend with the rate and the delay of `repeat_info`. `wait` shortens its timeout to the next repeat.
- The program has the commands of ztk and of ztcl without a capability. `exit ?code?` ends the program with that status.
- The program prints `frames: N` to stderr at the end.

## The render thread (task 17b)

- The `ztk` program draws on the render thread with the headless backend. The Wayland backend draws in `inline_draw` mode, because the libwayland objects and the buffer flags belong to the UI thread. A change to a thread-safe draw on Wayland is Stage 2.
- The Vulkan renderer is not a target of the App in Stage 1 (see `docs/dev/tasks/BLOCKED.md`), so no test draws the GPU image on the render thread.
- The test `renderthread: submit does not block` allows 5 submits of 1000 to take more than 0.5 ms. A submit that waits for the render thread (1 ms per draw in that test) would be slow for most frames. A strict limit of 0.2 ms for each submit failed 1 run of 200 on the shared machine.
- Measured on 2026-11-23: 200 runs of `zig build test -Dtest-filter=renderthread` gave 0 failures with the final test code.

## Frames, transitions, statistics, and memory (task 18)

- A transition moves the colors (`color`, `background`, `background2`, `border_color`, `outline_color`, `caret_color`), `opacity`, `radius`, and `box-shadow`. Padding, border width, font, and the minimum size change at once. The timing is `ease`, or `linear` when the declaration says so. Only the first duration of a `transition` declaration counts.
- The program prints `frames: N` to stderr, not to stdout, so a script that prints with `puts` keeps a clean output for the oracle.
- `ZTK_NO_ANIMATION=1` sets each duration to 0 in the program. The tests use `Harness.init`, which turns the transitions off, and `Harness.initAnimated`.
- The statistics use the system clock, also with the headless backend and its manual clock.
- `memory: 1000 labels leave no leak` and the other memory tests use 1 000 labels, not the 10 000 of the task. The cost of a command registration in ztcl grows with the number of commands: 4 000 `proc` definitions take 4.6 s in a `ReleaseFast`-less run of `zig-out/bin/ztk` (a Debug build, 2026-11-23). The ztk side was not profiled alone.
- The memory of one label was measured for the arena of the interpreter only: 927 bytes (command: `zig build test -Dtest-filter="bytes for each"`, 2026-11-23). The bytes of the allocator of ztk for one label were not measured.
- `maybeCompact` works with the pinned ztcl. A compact of ztcl keeps the commands, the variables, the bindings of ztk, and the pending `after` entries. It drops the variable traces, the command traces, and the `array` searches. It keeps the value of `tcl_precision` with no copy, so ztk stores that value as an integer first. ztk adds its own traces again after each compact (class hook `retrace`). A trace is the trace of ztk only when its operation, its variable, and its full script are the ones that a live widget or the parked wait added. The test `review B9 and M10` runs a real compact through `maybeCompact` and checks the text of a label and an entry, and a cached binding with a `%` field. With 100 000 motion events and a compact each 1 000 events, the arena stays at 41 068 bytes.
- The cost of the rule in `src/compact.zig`: while a script has a variable trace, a command trace, or an open `array` search, or has renamed `trace`, or has a `tcl_precision` text that is not a plain integer, no compact runs and the arena of the interpreter grows. The growth stops when the script removes that state. A renamed `trace` stays renamed until the script puts it back.
- A compact runs only with no script on the stack. A top-level `vwait` or `tkwait window` of the main script runs with no script on the stack, so it compacts (a script that allocates 600 MB in `after` callbacks under `vwait` peaks at 12.3 MB of resident memory, and at 581.8 MB before this change: `ztk --headless`, ReleaseFast, 2026-11-23). A wait inside a proc, a body, or a callback does not compact, and the arena grows until it returns.

### The benchmark (`zig build bench`, ReleaseFast, 2026-11-23, development machine with a load of 6 to 12)

| Case | Median | 99th percentile | Limit | Result |
|---|---|---|---|---|
| build-1000 | 23.6 ms | 25.0 ms | none | |
| frame-full-1000 | 1.11 ms | 1.23 ms | none | |
| frame-hover-1000 | 0.66 ms | 0.85 ms | under 4 ms (99th) | met |
| frame-text-1000 | 0.65 ms | 0.89 ms | under 4 ms (99th) | met |
| idle-1000 | 0.004 us | 0.007 us | under 5 us | met |
| type-entry | 24 us | 37 us | none | |
| demo-start | 1.94 ms | 2.11 ms | under 30 ms | met |
| cpu-render-demo | 10.8 ms | 11.0 ms | none | |

## The demo (task 19)

- `examples/demo.tcl` runs in ztk and in `wish` 8.6.16 as written. `tests/demo.sh` prints no difference for the 16 lines of values that it compares (2026-11-23).
- The scene check `text_clipped` compares the measured text size with the content rectangle and with the clip of the parents. A glyph quad has no link to its widget, so the check does not read the quads.
- The live session check (a window for 300 frames on the desktop of the user) was not done. The demo ran on a private headless sway with `ZTK_FRAME_STATS=1 ztk --exit-after-frames 8 examples/demo.tcl` (CPU path, 800 by 600 window). In a Debug build: late 6 of 8 frames, first frame 16.5 ms, render p50 15.9 ms. In a ReleaseFast build: late 0 of 8, first frame 3.0 ms, render p50 2.8 ms (2026-11-23). The demo is static, so it draws a frame only for the caret, and the 60 frames in each second of a hover transition were not measured on a display.
- The Vulkan test also draws the scene of `demo-start`: the worst difference from the CPU image is 1 level on the Intel device and 2 on the NVIDIA device.

## The direct backend (task 20)

- The output is the framebuffer with the CPU renderer. `--output vulkan` is not available (see `docs/dev/tasks/BLOCKED.md`).
- The key layout is the US layout only. The table has the letters, the digits, the punctuation, space, Return, Tab, Escape, BackSpace, Delete, Insert, the arrows, Home, End, Page Up, Page Down, the modifiers, and F1 to F12. Other layouts are Stage 2.
- A mouse gives a pointer of 10 by 16 pixels that the output draws into the image before the present step. A touch panel shows no pointer.
- Scroll gestures and the fling are Stage 2. `src/platform/touch.zig` has the numbers of the lessons in a comment.
- `-Dbackends=direct,headless -Dvulkan=false` gives a static program (x86-64, checked 2026-11-23). The program runs the demo on the headless backend. The build with the GPU links libc only (checked with `ldd`).
- The input discovery reads `/sys/class/input/event*/device/capabilities` and opens `/dev/input/event*`. It was not run on this machine.
- `--direct` does not start without `--direct-unsafe-test-device`. ztk does not own the VT: it has no `KDSKBMODE`, no termios change, no `VT_SETMODE`, and no handling of a VT switch. On a real console the keyboard still types into the console, and a VT switch draws over the other VT.
- `--tty` must be a path of the form `/dev/tty<N>` with N from 1.
- The backend fails closed. It refuses to start when `WAYLAND_DISPLAY`, `DISPLAY`, or an `XDG_SESSION_TYPE` of x11 or wayland is set, when the standard input is not a VT and `--tty` is not given, when the VT is not the active one, and when the console is already in graphics mode. The tests of these checks use a fake host. No test opened a real terminal, framebuffer, or input device, and `zig-out/bin/ztk --direct` was not run on a device.
- A failed `KDSETMODE` stops the start before any drawing. The console goes back to its old mode on each signal whose default action ends the program, on `exit`, on a panic, and on a normal end. A signal that the program ignored before the start stays ignored and does not change the mode. When an old handler of a signal returns, the program ends, because the console is in text mode. A `SIGKILL` and a power loss leave it in graphics mode. `SIGTSTP` keeps its action, so a stopped program leaves the console in graphics mode until it continues. The stack of the signal handler is set on the main thread only, so a stack overflow on the render thread does not restore the console. The tests raise 12 of these signals in the test process with a fake host. No test has a real fault or a real console.
- A scene that is larger or smaller than the panel (a scale that does not divide the panel size) is cut or padded with black.
- The panel is the visible mode of the device (`xres` by `yres`) at its pan offset, from `FBIOGET_VSCREENINFO` and `FBIOGET_FSCREENINFO`. A later pan by another program is not followed. A pixel format other than XRGB8888 or RGB565 gives `error.UnsupportedDepth`.
- A framebuffer with a width or a height of 0 or above 16384, a stride below one row, a visible area outside the virtual area, or memory below the end of the visible rows gives `error.BadFramebuffer`.
- When an input device goes away, ztk sends the release of each key (up to 8 for each device), modifier, button, and touch that the device held.
- An input device that gives an error other than "no data yet", or the end of the file, is closed and not read again.
