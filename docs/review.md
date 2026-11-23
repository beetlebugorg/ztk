# Review checklist

The reviewer uses this page for each task of [Stage 1](tasks/README.md). The reviewer reads the task file first, then the commits of the task, then runs the commands.

A review has one of three results: **accept**, **change** (a list of findings, each with a file and a line), or **blocked** (the task file is wrong or not possible). Do not accept a task with an open finding of sections 1 to 5.

## 1. The task is done

- [ ] Each file of the "Files" list exists, or the commit message says why not.
- [ ] Each interface has the signature of the task file. A difference has a reason in the commit message and is in `docs/stage1-report.md` under "Differences from the plan".
- [ ] Each step of the task is in the code. Search for the behavior, do not trust the commit message.
- [ ] Each test of the "Tests" list exists as a test, with the name that the filter of the task finds.
- [ ] Each point of "Acceptance" is true. Run its command.
- [ ] The commit has no work from "Out of scope" and no work of a later task.

## 2. The tests are real

- [ ] Run the exact commands of the task, under the memory cap. Copy the pass, fail, and skip counts.
- [ ] `zig build test` passes for the complete repository, and not only the filter of the task.
- [ ] No test has an assertion that is always true, an expected value that the test computes with the code under test, or a body that returns early.
- [ ] A skipped test prints `SKIP:` and its reason. Count the skips. A skip for a thing that this machine has (a GPU, `wish`, `Xvfb`, `weston`, `fontTools`) is a finding.
- [ ] Break the code in one place of your choice (for example change a `+` to a `-` in the grid solver) and check that a test fails. Put the code back. Do this for each task with logic.
- [ ] Each expected text that the task says is from `wish` is equal to the output of `wish` 8.6.16. Run `wish` for at least five of them:
  ```sh
  printf 'catch {frame .x.y} m; puts $m; exit\n' > /tmp/t.tcl && xvfb-run -a wish /tmp/t.tcl
  ```
- [ ] The oracle commands print no difference. Run them with a new seed too: `tools/oracle.sh tools/oracle-grid.tcl 99 200`.
- [ ] No test sleeps for real time, opens a real window, or writes outside the repository and the temporary folder, unless the task says so.

## 3. The pictures are correct

A test that compares an image with itself proves only that the image did not change. The reviewer must look.

- [ ] Open each new or changed PNG in `tests/golden/`. Say in the review what each one shows. An image that does not show what its name says is a finding.
- [ ] Check in each image: smooth corners, a complete border, no gap between a border and its fill, text on one straight baseline, even space between letters, no glyph cut by its widget, the focus outline on all four sides.
- [ ] Read the scene dump beside each image. The count of quads fits the picture, and no quad is outside the scene.
- [ ] A golden file changed in a commit that does not change that output on purpose is a finding.
- [ ] For the Vulkan task: the fragment shader and `src/render/renderer.zig` have the same formulas. Read them side by side. The tolerance in the test is the number of the task and was not raised.
- [ ] The scene checks of task 19 pass in the light and the dark scheme, at the scales 1, 1.25, and 2, and at 1.5 times the font size.
- [ ] For the font engine: `text-large` has smooth curves, no spike, and open counters in `a`, `e`, `g`, `R`, `&`, and `@`.

## 4. The rules for sources and licenses

- [ ] No code of Tk: no translated C function, no copied Tcl binding script, no copied comment. Compare a suspicious function with the Tk source in `.tk-src/` when one exists.
- [ ] No code of a project with a GPL, LGPL, or AGPL license. zslice and Printdeck have the AGPL. A function that looks like a translation of Printdeck code is a finding.
- [ ] No code of FreeType, HarfBuzz, `stb_truetype`, or another font library in `src/text/`.
- [ ] Each new source of an idea, a table, or a method has an entry in `docs/references/`.
- [ ] Each new dependency is in section 6 of the plan. `build.zig.zon` has only ztcl and the Vulkan headers. `build.zig` links only what section 6 lists for the backend.
- [ ] The dependency rule holds. Run:
  ```sh
  zig build -Dbackends=direct,headless -Dvulkan=false -p /tmp/ztk-static && file /tmp/ztk-static/bin/ztk
  ldd zig-out/bin/ztk
  grep -rn cImport src/ | grep -v -E 'src/platform/wayland|src/render/vulkan|src/platform/vkdisplay'
  ```
  The first prints `statically linked` (from task 20). The second lists libc, the Wayland client library, `libxkbcommon`, and what they need, and no Vulkan loader. The third prints no line.
- [ ] A font or another binary file in the repository has its license file beside it.
- [ ] Each source file starts with a `//!` comment that explains what it does and how, and has the SPDX line for BSD-2-Clause.
- [ ] The repository names no AI model and no AI vendor. Search the files and the commit log for the name of each AI model and each AI vendor that you know. The list of names is not in this page on purpose. Also run:
  ```sh
  git grep -n -i -E 'co-authored-by|generated with|session link'
  git log --format='%an <%ae>%n%B' | grep -n -i -E 'co-authored-by|generated with|noreply'
  ```
  Both print no line, except this page and the rule in `AGENTS.md` and `WRITING.md`. A match that is an ordinary word of the domain (for example a musical work in a font name) is not a finding. Say which one it is.
- [ ] No local path and no private data: `git grep -n -E '/home/|/Users/'` prints no line, except this one. A command example can use `/tmp/`.

## 5. The ztcl binding

- [ ] ztk keeps no `ztcl.Value` and no slice of the ztcl arena after a command returns. Check each struct field with a string: its bytes come from the allocator of the `App`.
- [ ] A script that runs many times is compiled one time and compiled again after a compact (task 18). `it.eval` in a path that runs for each event is a finding, unless the script has `%` fields.
- [ ] Each callback runs at the global level and puts `it.frame` and `it.ns` back, also on an error.
- [ ] A widget that is deleted during its own callback gives no use after free. Find the test for it in tasks 12, 14, and 15.
- [ ] The ztk library turns on no capability of ztcl. Only `src/main.zig` can, from a flag.
- [ ] `ztk::style load` reads no file outside `style_root`.
- [ ] No file other than `src/loop.zig` has a timer list or registers `after`, `update`, `vwait`, or `tkwait`.
- [ ] An error in a callback reaches `bgerror` or the error output. No error is dropped with an empty `catch`.

## 6. Robust code

- [ ] The CSS parser and the font parser take input that a script or a file controls. They have no `unreachable`, no `catch unreachable`, and no index without a length check on that path. Their random-input tests exist and run in a safe build mode.
- [ ] No leak: the tests use `std.testing.allocator`, and the tree test of task 02 and the label test of task 18 pass.
- [ ] No global mutable state, except what the task file names. Two `App` values in one process work (find or write a test).
- [ ] An allocation failure returns an error. It does not crash, except in a test.
- [ ] Integer conversions of sizes and positions from a script cannot overflow: `frame .f -width 99999999999` gives an error or a limit, and no crash.
- [ ] The render thread reads only its own frame. Read each field that two threads use: it is under the one mutex or it is atomic. Run the tests of task 17b 200 times.
- [ ] The direct backend sets the console back to text mode on each exit path, and it creates no display surface in a test on the development machine.
- [ ] The Wayland backend and the Vulkan renderer free each object at the exit. The smoke test with validation prints no message.

## 7. Performance

- [ ] Each speed test of a task prints its time, and the time is under the number of the task in `ReleaseFast`. Run it two times. Write both times in the review.
- [ ] `App.frame` with no dirty flag does no work. A hover computes one style. A text change with the same size runs no layout of other widgets.
- [ ] No frame and no timer run when the window is idle (the idle test of task 18).
- [ ] The paint path and the present path allocate no memory after the first frame, where the task says so.
- [ ] `zig build bench` prints each case. A case over its target is in the report as "not met". It is not hidden.

## 8. Writing

- [ ] Comments, docs, and commit messages follow [WRITING.md](../WRITING.md): short sentences, active voice, present tense, no figures of speech.
- [ ] Each commit message passes the check of the project for banned words, line length (72), and attribution lines.
- [ ] One commit does one thing. The subject says what changed.
- [ ] Each number in a doc has the command that measured it, the date, and the machine.
- [ ] A fact that was not checked says so in its sentence.
- [ ] The names of [WRITING.md](../WRITING.md) are used with one meaning each.

## 9. Honest reports

- [ ] `docs/stage1-limits.md` lists each option, subcommand, and event type that a Stage 1 widget does not have. Compare it with `configure` of the same widget in `wish` for `label`, `button`, and `entry`.
- [ ] `docs/tasks/BLOCKED.md` has each step that the implementer did not do, with the exact error. A task that is "done" with a missing step and no entry is a finding.
- [ ] The stage report has each target of section 7 of the plan with "met" or "not met".
- [ ] Each item that needs a person is "done" with a date and a result, or "not done". The implementer did not mark a manual check as done.
- [ ] The README says what works and what does not. It keeps the Experimental notice and the AI disclaimer.
- [ ] The pass counts in the report are equal to the counts of your own run.

## 10. What the reviewer cannot check

Write this list in each review, so that the user knows what is still open:

- The look of the real window on the Wayland session, beside native programs.
- Input with a real keyboard, pointer, and touch panel.
- The frame rate that a person sees during a resize.
- The direct backend on a real device: the Vulkan output, the framebuffer output, and the console.
- A display with a fractional scale, and two displays with different scales.
- Each compositor other than the one of the development machine.
