# Stage 1 tasks

Stage 1 is the demo: `examples/demo.tcl` opens a window on Linux, with `grid`, labels, buttons, and an entry, with `bind`, with a CSS stylesheet, and with a GPU renderer at 60 frames in each second. The same demo also draws directly on the display of a Linux device with no display server: with Vulkan on the display, or on the CPU to the framebuffer. [The plan](../plan.md) has the design.

Do the tasks in order. One task is one commit, or a few commits when the task says so. Do not start a task before the tests of the task before it pass.

| # | Task | Needs | ztcl event loop |
|---|---|---|---|
| 01 | [Project skeleton](01-skeleton.md) | | |
| 02 | [App, widget tree, `frame`, `destroy`, `winfo`](02-widget-tree.md) | 01 | |
| 03 | [Options: `configure` and `cget`](03-options.md) | 02 | |
| 04 | [The event loop adapter](04-loop.md) | 02 | **yes** |
| 05 | [The backend interface and the headless backend](05-headless.md) | 04 | |
| 06 | [The scene, the CPU renderer, and golden images](06-scene-cpu.md) | 01 | |
| 07 | [Text: the built-in font engine](07-text.md) | 06 | |
| 08 | [The CSS parser](08-css-parser.md) | 01 | |
| 09 | [Selectors, the cascade, and `ztk::style`](09-style.md) | 03, 07, 08 | |
| 10 | [`grid`](10-grid.md) | 03 | |
| 11 | [The frame pipeline, `.`, `frame`, `label`, and `wm`](11-frame-label.md) | 05, 07, 09, 10 | |
| 12 | [Events, `bind`, and `event generate`](12-bind.md) | 11 | uses 04 |
| 13 | [Focus](13-focus.md) | 12 | |
| 14 | [`button`](14-button.md) | 13 | |
| 15 | [`entry`](15-entry.md) | 14 | uses 04 |
| 16 | [The Vulkan renderer](16-vulkan.md) | 07 | |
| 17 | [The Wayland backend and the `ztk` program](17-wayland.md) | 15, 16 | |
| 17b | [The render thread](17b-render-thread.md) | 17 | |
| 18 | [Frame pacing, transitions, statistics, and memory](18-frames.md) | 17 | uses 04 |
| 19 | [The demo, the scene checks, and the end-to-end tests](19-demo.md) | 18 | |
| 20 | [The direct backend](20-direct.md) | 19 | |
| 21 | [The Stage 1 report](21-report.md) | 20 | |

Tasks 06, 07, 08, and 16 need no widget code. They can go before their place in the order when another task is blocked. The framebuffer output of task 20 does not need tasks 16 and 17.

Tasks 06, 07, 12, 18, 19, and 20 use what the Printdeck project learned with its own UI framework on a small touch screen. [The lessons](../references/printdeck.md) has the facts. The implementer reads that page and does not open the Printdeck source, because Printdeck has the AGPL.

## The ztcl event loop

The event loop of ztcl (`after`, `vwait`, `update`, `fileevent`) is not on the `main` branch of ztcl at commit `125392f`. Stage 1 does not wait for it.

- Task 04 makes `src/loop.zig`. It has the timers and the idle list of ztk, and it registers `after`, `update`, `vwait`, and `tkwait`.
- All other code calls only the functions of `src/loop.zig`. No other file registers a timer command.
- When the loop of ztcl is on `main` **and** it has the event source of request 2 in [the plan](../plan.md#10-what-ztk-needs-from-ztcl), a later task changes the inside of `src/loop.zig`. The tests of task 04 stay and must still pass.
- When the loop of ztcl is on `main` without that event source, keep the loop of ztk. Do not turn on the `event` capability of ztcl, because then two sets of timers exist.
- Before task 04, check the pinned ztcl: `it.findCommand("after")` in a test. If the pinned ztcl has `after` with no capability, stop and report. That is a change of ztcl that this plan does not cover.

## Rules for each task

1. Use Zig 0.16.0. Check with `zig version`.
2. Run each build, test, and benchmark under the memory cap:
   ```sh
   systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 -- <command>
   ```
   The commands in the task files do not show the cap. Add it to each one.
3. Stop only your own processes, by PID. Do not use `pkill -f`.
4. Work only in the ztk repository. Read ztcl through the pinned package. Do not change the local ztcl folder, and do not read the zslice source or the Printdeck source.
5. Read [WRITING.md](../../WRITING.md) before the first comment and the first commit.
6. Start each source file with a `//!` comment that explains what the file does and how, and an SPDX line: `// SPDX-License-Identifier: BSD-2-Clause` (inside the `//!` block, as ztcl does).
7. Add no dependency that the plan does not list. Stage 1 links only the Wayland client library, `libxkbcommon`, and libc for the Wayland backend, and opens the Vulkan loader at run time. The core, the text code, the headless backend, and the direct backend link no library.
8. ztk keeps its state in the allocator of the `App`. It keeps no `ztcl.Value` and no slice of the ztcl arena after a command returns. Copy what must stay.
9. Each error message that Tk also has is the same text as in `wish` 8.6.16. Run `wish` to get the text. Do not guess it.
10. Each behavior comes from the manual page or from a run of `wish`. Copy no code from Tk. Add an entry in `docs/references/` for each new source.
11. A test that needs something the machine does not have (a GPU, a Wayland compositor, `wish`) skips with a message that names the missing thing. It does not pass silently, and the report counts it as skipped.
12. Do not change a golden file to make a test pass, unless the task changes that output on purpose. Say so in the commit message.
13. Run `zig build test` before each commit. All tests pass.
14. A commit message passes `WRITING.md`. It names no AI model and no vendor, and has no attribution line.
15. When a step of a task is not possible, stop and write the reason in `docs/tasks/BLOCKED.md`: the task, the step, what you tried, and the exact error. Then go to the next task that does not need the blocked one.
16. When a task file and the manual page of Tk disagree, the manual page and `wish` win. Note the difference in the commit message.

## Facts about the build that were checked

These were checked on the development machine on 2026-11-23 with a scratch program.

- A Zig 0.16.0 program that links the system libc fails in the linker of Zig: `unhandled relocation type R_X86_64_PC64` in `crt1.o`, section `.sframe`. Set `use_llvm = true` and `use_lld = true` on each executable and each test that links libc. Then it links and runs.
- `@cImport` works for `wayland-client.h`, `xkbcommon/xkbcommon.h`, and `vulkan/vulkan.h`.
- `Module.linkSystemLibrary(name, .{})` finds `wayland-client` and `xkbcommon` through `pkg-config`.
- The machine has no Vulkan headers in `/usr/include`. The build must get them from a package (task 16).
- `std.DynLib.open("libvulkan.so.1")` opens the Vulkan loader at run time, and `vkGetInstanceProcAddr` from it gives the other functions. The program then has no link to the loader.
- `vkCreateInstance` works and reports two physical devices. The machine has no software Vulkan driver.
- The loader lists the instance extensions `VK_KHR_display`, `VK_KHR_wayland_surface`, and `VK_EXT_headless_surface`.
- A program with ztcl and no libc builds as a static executable (`file` prints `statically linked`) and runs. The same program builds with `-Dtarget=aarch64-linux`. The ARM program was not run.
- Python has the package `fontTools` 4.67.0, and `ttx` is on the path. `hb-shape` is not on the machine.
- `glslc`, `wayland-scanner`, `weston`, `sway`, `Xvfb`, `xvfb-run`, `wish` 8.6.16, and `tclsh8.6` are on the path.
- `wayland-protocols` 1.49 is in `/usr/share/wayland-protocols`.
- `std.compress.flate` has `Compress.zig` and `Decompress.zig`.
- `std.Build.TestOptions` has the fields `filters`, `use_llvm`, and `use_lld`.
- `examples/demo.tcl` of task 19 runs in `wish` 8.6.16 as written in that task.

## The ztcl interface

The signatures are from ztcl commit `125392f`. Check them in the pinned package before use.

```zig
const ztcl = @import("ztcl");
// ztcl.Interp, ztcl.Value, ztcl.Error
// ztcl.interp.NativeFn = *const fn (it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value
// ztcl.interp.Command { name, impl, ctx: ?*anyopaque, traces }

it.init(gpa)                          // the Interp must not move after init
it.register(name, native_fn)          // then: it.findCommand(name).?.ctx = ptr
it.findCommand(name) ?*Command
it.eval(text) Error!Value             // copies and parses the text at each call
it.compile(text) Error!*Script        // text must stay valid as long as the script
it.evalTop(script) Error!Value
it.callWords(argv) Error!Value
it.str(v) / it.list(v) / it.int(v)
it.setVar(name, v) / it.getVarOpt(name)
it.fail(fmt, args) Error              // sets the result, returns error.TclError
it.wrongArgs(usage) Error
it.alloc()                            // the arena of the interpreter
it.result                             // the message after error.TclError
it.frame, it.global, it.ns            // set frame = &global and ns = "" for a callback
```

`argv[0]` of a native command is the command name.

## Names used in all tasks

| Name | File | Meaning |
|---|---|---|
| `App` | `src/app.zig` | One ztk instance on one interpreter |
| `Widget` | `src/widget.zig` | One node of the widget tree |
| `Class` | `src/widget.zig` | The table of a widget class |
| `Loop` | `src/loop.zig` | Timers, idle work, and the wait |
| `Platform`, `Window` | `src/platform/platform.zig` | The backend interface |
| `Event` | `src/event.zig` | One input event |
| `Scene`, `Quad` | `src/scene.zig` | What a frame draws |
| `Renderer` | `src/render/renderer.zig` | The interface of the CPU and Vulkan renderers |
| `Style` | `src/style.zig` | The computed style of a widget |
| `Harness` | `src/testing.zig` | An interpreter, an `App`, and a headless backend for a test |
