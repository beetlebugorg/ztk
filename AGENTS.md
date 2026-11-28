# Agent instructions

ztk is an experimental Tk replacement in Zig, on the ztcl interpreter. The repository has the plan and the code of Stage 1.

Read these pages before you work:

1. [WRITING.md](WRITING.md), before you write code comments, commits, or PRs.
2. [docs/dev/plan.md](docs/dev/plan.md), the design and the decisions.
3. [docs/dev/tasks/README.md](docs/dev/tasks/README.md), the rules for a task, and then the file of your task.
4. [docs/dev/review.md](docs/dev/review.md), the checklist that the reviewer uses on your work.
5. [docs/dev/architecture.md](docs/dev/architecture.md), before you add or move a file in `src/`. It has the areas, the rules of the layers, and the folder of each kind of feature.

Put plans, task lists, reports, and limits in `docs/dev/`. The docs site publishes only the user pages that `tools/build-docs.py` lists. A new widget gets a section on its page in `docs/widgets/` and a line in `docs/differences.md`.

The CPU limit of ztcl is the compute limit, and it counts compute units. Use these terms in code, docs, and messages. `ztk::limit -compute N` sets it.

## Commands

Use Zig 0.17.0. Run each build, test, benchmark, and suite command under a memory cap:

```sh
systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 -- <command>
```

| Command | What it does |
|---|---|
| `tools/fetch-tk.sh [tag]` | Downloads a Tk release into the ignored folder `.tk-src/`. |
| `python3 -I tools/tk-count.py .tk-src/core-8-6-16` | Counts the manual pages and the tests of Tk. |
| `xvfb-run -a wish tools/tk-introspect.tcl` | Counts the commands and the options of a real `wish`. |
| `xvfb-run -a tools/tk-run.sh .tk-src/core-8-6-16 <work folder>` | Runs the tests of Tk on a real `wish`. |

| `zig build` | Builds `zig-out/bin/ztk`. |
| `zig build test` | Runs all unit tests. `-Dtest-filter=<text>` runs the tests with that text in the name. |
| `zig run tools/modmap.zig` | Prints the module map of `src/`: the imports, the importers, and the tests of each file, the cycles, and the layering breaks (`docs/dev/architecture.md`). |
| `zig build run -- file.tcl` | Runs a script. |
| `tools/oracle.sh script.tcl args` | Runs a script in `wish` and in `ztk --headless`, and prints the difference. |
| `tools/oracle.sh tools/oracle-pack.tcl seed count` | Compares random `pack` layouts with `wish`. `oracle-place.tcl` does the same for `place`. |
| `zig-out/bin/ztk [flags] script.tcl` | Runs a script. See `ztk --version` and the flags in `docs/dev/tasks/17-wayland.md`. |
| `ZTK_HEADLESS=1 ./app` | Runs a bundled app (`ztk bundle`) or `ztk` with the headless backend. A bundled app reads no flag. |
| `tests/bundle-headless.sh [ztk]` | Bundles a script into one program file and runs it with `ZTK_HEADLESS=1` and no display. |
| `zig build runtimes` | Builds the `ztk` program of each target of `ztk bundle --target` into `zig-out/lib/ztk/runtime/TARGET/`, with the full GUI backend of each platform. `-Druntime-targets=a,b` builds a part of them. |
| `tests/bundle-backends.sh [ztk] [target ...]` | Bundles a script for each target in `zig-out/lib/ztk/runtime` and checks that each program file has the full GUI backend of its platform. |
| `zig build test -Dtarget=x86_64-linux-musl -Dtest-filter=vulkan` | Runs the Vulkan tests in a static program, which opens the Vulkan loader and the driver with `src/sys/elf/loader.zig` (docs/dev/elf-loader.md). `-Dtest-filter=elf` runs the tests of the loader. |
| `tests/static-vulkan.sh` | Runs the same tests with `VK_LOADER_DEBUG=error,warn`. After 600 seconds it prints the stack of each thread with gdb and stops the run. |
| `tests/wayland-smoke.sh` | Runs `ztk` on a private headless compositor. |
| `tests/wayland-gpu.sh [ztk] [render node]` | Runs `ztk` on a private headless sway with the GLES2 renderer, with `ZTK_RENDERER=vulkan` (dma-bufs) and `ZTK_RENDERER=cpu`, and compares a `grim` shot of each. It needs a render node such as `/dev/dri/renderD128`. |
| `tests/dbus.sh` | Runs the D-Bus tests on a private session bus of `dbus-run-session`: the SASL lines, `Hello`, a call, a match, and an error reply. The tests of `src/platform/portal.zig` use a fake bus on a socket pair. |
| `tests/wayland-input.sh [ztk]` | Sends keys, a resize, the scale 1.5, and the clipboard to `ztk` on a private headless sway, with `wtype` and `wl-copy`. |
| `tests/wayland-icon.sh [ztk]` | Runs `wm iconphoto` on the small Wayland server of `tests/wayland/icon-server.py`, which has `xdg-toplevel-icon-v1`, and compares the icon buffers with the photos. |
| `tests/x11-icon.sh [ztk]` | Runs `wm iconphoto` on a private Xvfb and compares `_NET_WM_ICON` with the photos. It needs `xprop`. |
| `ZTK_WAYLAND_DEBUG=1 zig-out/bin/ztk script.tcl` | Prints each Wayland event to stderr: the interface number, the object, and the opcode. |
| `python3 -I tools/gen-keysyms.py /usr/include/X11/keysymdef.h > src/platform/wl/keysyms.zig` | Makes the key symbol table of the Wayland backend again. |
| `tools/shots.sh [folder]` | Draws the screenshots of the examples into `docs/site/shots`, in light and dark at scale 2. |
| `zig build libztk` | Builds `zig-out/lib/libtcl8.6.so` and `libtk8.6.so` for Python's tkinter and other programs of Tk 8.6, and `zig-out/include/tk.h` (docs/python-tkinter.md). |
| `tests/libztk.sh [libdir]` | Runs the Python programs of `tests/libztk/` on libztk with the headless backend and compares their output. |
| `tools/libztk/bench.sh LIBDIR\|tk` | Times the startup and a widget-heavy window of tkinter in a private Xvfb, on libztk or on the Tk of the system. |
| `tests/apps/savi/run.sh SRC TCLINC [libdir] [shots]` | Builds the pinned SaVi release against libztk with no change and runs it headless with `tests/apps/savi/shots.tcl`. |
| `zig build wasm` | Builds the browser files into `zig-out/web`: `ztk.wasm`, `ztk.js`, the playground `index.html`, and the examples. |
| `tests/web.sh` | Runs the demo and the gallery in a headless Chromium: DOM input, the accessible roles, WebGPU, WebGL 2, and the CPU renderer in a 2D canvas against the native CPU renderer, a display-p3 canvas, a WebGPU device loss, the CPU time of a frame with WebGPU and with WebGL 2, and the frame time in V8. It needs `node`. |
| `tests/site.sh` | Builds the site with the web build, makes each card of the landing page go live in a headless Chromium, compares its first frame with its poster in light and dark, and sends a click, text, and a toggle. It then checks the size and the aspect ratio of each canvas of the playground and the landing page at three page sizes and the pixel ratios 1, 2, and 3. That check needs `node`. Last, `tests/toy-keys.mjs` checks the keys of the handheld of the Toys page, and `tests/inspect.mjs` checks that the panel of Inspect opens in view and off its widget, its tabs, and the console. `tests/debug-form.mjs` checks the console of the page Debug a form. Set `PYTHON` to a Python with `markdown-it-py` and `Pillow`. |
| `tests/shots.sh` | Checks that the files in `docs/site/shots` equal new shots, and runs each example in `wish`. |
| `tests/docs-live.sh [page]` | Builds the site with the web build and runs each live snippet of the docs pages in a headless Chromium, in light and dark. A snippet with a plain shot must equal its shot, and the first snippet of each page gets edits. It needs `node`. Set `PYTHON` as for `tests/site.sh`. |
| `tests/skill.sh` | Runs the check script of `skills/ztk-app/SKILL.md` and of `docs/agents.md` in `ztk --headless`. Each must print `n = 1`. |
| `tests/api-index.sh` | Checks that `docs/site/api.json`, the API index for agents, equals the output of `tools/api-index.tcl` on this build. The top of the file has the command that writes it again. |
| `node tests/stage.mjs chromium URL` | Steps through the stage of a build replay (for example `/toys/backspin/` of a site build) with the arrow keys. Each step must pass its check and keep scrollY and the boxes of the stage, and the mark must be on the canvas. It prints the frame times. |
| `tests/debug-form.sh` | Runs the form of `docs/debug-a-form.md` in `ztk --headless` with its bugs and with its fixes, and checks the answers of `ztk::debug` that the page shows. |
| `tests/replay.sh` | Runs the script and the check of each step of each replay in `docs/site/replays` in `ztk --headless`. Each check must give 1. |
| `ZTK_TEST_WINDOWS=1 zig build test -Dtest-filter=windows` | On Windows: runs the tests of the Win32 backend with hidden windows. Without the variable they print `SKIP:`. |
| `ZTK_RENDERER=cpu\|d3d12\|warp zig-out/bin/ztk script.tcl` | On Windows: runs a script in a window with the CPU output, Direct3D 12, or Direct3D 12 on WARP. The default is Direct3D 12, and the CPU output when no device exists. |

Each later task adds its commands to this table.

## Rules

1. Do one task at a time, in the order of the task index. Do what the task file says and stop at its "Out of scope" list.
2. Run `zig build test` before each commit. The tests must pass.
3. Add no dependency that section 6 of the plan does not list. ztk needs only the interfaces of the platform, ztcl, and the Zig standard library. The core, the text code, the headless backend, and the direct backend link no library.
4. Copy no code from Tk, and no code from a project with a GPL, LGPL, or AGPL license. zslice and Printdeck have the AGPL: do not open their source for a ztk task. Follow the manual pages of Tk and the behavior of `wish` 8.6.16. Credit each source in `docs/references/`.
5. The ztk library turns on no capability of ztcl and reaches the host only through its backend. Only the `ztk` program turns on a capability, from a flag.
6. ztk keeps its state in its own allocator. It keeps no value of the ztcl arena after a command returns.
7. Each number in a doc is measured. Give the command, the date, and the machine. A test that did not run is skipped or blocked. It is not a pass.
8. Do not change a golden file to make a test pass.
9. Start each source file with a `//!` comment that explains its algorithm, and an SPDX line for BSD-2-Clause.
10. Do not name an AI model or an AI vendor in a file or in a commit message.
11. Keep local paths and private data out of the repository.
12. Stop only your own processes, by PID. Do not open a window on the live desktop session, and do not create a display surface with the direct backend on the development machine, unless a task says so.
13. Do not change the ztcl repository. A request to ztcl goes in the report of your task.

## Token use

Use as few tokens as the work permits. These rules apply to your thoughts, to the messages between agents and sessions, and to the tool calls. They do not apply to the text that a person reads: commits, PRs, issues, docs, and the report to the user follow WRITING.md.

Thoughts and messages between agents:

- Write in short form: symbols, issue numbers, paths, and key words. Write no full sentences, no greeting, and no summary of what the reader knows.
- State a decision one time. Do not list the options that you do not use.
- A message to an agent has the goal, the scope, the rules that differ from this file, and the form of the report. Point to a file or an issue. Do not copy its text.
- An agent reports one line for each item: the issue, the PR, the state. It reports at the end, or when it cannot continue.

Tool calls:

- Put the commands that do not depend on each other in one call.
- Limit each output: `grep -n` with a pattern, `sed -n A,Bp`, `head`, `tail`, `--json` with `-q`. Do not print a full file or a full log.
- Read only the part of a file that the change needs. Do not read a file again after an edit.
- Send a long build, test, or suite to the background with its output in a log file. Read only the last lines of the log.
- Edit with one script for each change. Build and test in the same call.
- Use one worktree for each branch, so that tests of one branch run while you edit the next branch.

`ztcl code` (the module `ztcl::code`, `docs/modules/code.md` of ztcl) has tools with short output. Build the runner in the ztcl tree with `zig build`, and use its `zig-out/bin/ztcl code` in place of `grep`, `cat`, `sed`, and a direct run of a long command:

- Search and read: `ztcl code 'grep TEXT src -glob *.zig'`, `ztcl code def NAME`, `ztcl code outline FILE`, `ztcl code show FILE NAME` (the lines of one definition) or `ztcl code show FILE A-B`.
- Edit: `ztcl code replace FILE OLD NEW`, `ztcl code edit FILE {OLD NEW OLD NEW}`, `ztcl code lines FILE A B TEXT`. Each change prints one line.
- Run: `ztcl code run zig build test` gives the error lines and the tail, and keeps the full output in `.git/ztcl-code/run-N.log`. `ztcl code 'run -ask "QUESTION" {COMMAND}'` gives the answer of a cheaper model about the output.
- Put several commands in one script: `ztcl code 'def NAME` + newline + `show FILE NAME'`.

`ztcl code` has `exec`. Use it only on your own tree.

Work:

- Reproduce a bug with the smallest script before you read the code.
- For a difference from Tcl or Tk, generate many inputs, run them in the reference program (tclsh or wish) and in ztk, and diff the outputs. Fix until the diff is empty.
- Do not start an agent for work of a few tool calls. Start an agent for a set of issues that does not depend on your work.
- Tell the user only the result, the open decisions, and the failures.

## Commits and merges

- Follow the commit rules in WRITING.md.
- Add no attribution lines, co-author lines, or session links.
- Do not push, add a remote, or make a tag, unless the user asks.
- Merge by rebase only. Keep merge commits out of PR branches.
