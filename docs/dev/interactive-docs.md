# Interactive docs

The user asked on 2026-11-25 that the docs site be very interactive. The site has a Tcl interpreter and a GUI toolkit in the page, so each page can run, inspect, and change real ztk windows. This file is the design and the order of the work. Each item is one PR, and each PR is live on beetlebug.org/ztk after the merge.

## The base: the live snippet

A `tcl` block after a line `<!-- live -->` or `<!-- widget: NAME; shot: SCRIPT -->` becomes a live snippet. `tools/build-docs.py` writes a `<figure class="live-demo">` with the code, the screenshot of the widget, and a script tag for `assets/live.js`. The page loads no WebAssembly until a snippet comes near the viewport. Then `assets/live.js` imports `play/ztk.js`, compiles `play/ztk.wasm` one time for the page, and gives each snippet its own instance.

- The code is a text area over a highlighted `pre`, with no library. The highlighter has the token classes of `site.css`.
- The screenshot stays in place until the first frame. It also stays when the browser has no WebAssembly, or when the script fails on the first run.
- The window follows the color scheme of the page.
- Each widget page gets snippets and shots in the shape of `docs/dev/widget-pages.md`, so each widget has a live snippet.
- The interpreter has no capability of ztcl. The snippet runs in the sandbox of the browser, with no file, no network, and no process.

## The list, ranked by effect over cost

| Rank | Item | Cost | What the reader sees |
|---|---|---|---|
| 1 | Live as you type | Low | The window runs the code again 300 ms after the last key. An error shows under the code, and the last good window stays. The global variables of the last run go into the new run, so a toggle keeps its state. |
| 2 | Share and the playground | Low | A button copies a link with the code in the URL. A snippet opens in `play/` with its code. |
| 3 | Renderer switch and frame HUD | Low | A menu selects WebGPU, WebGL 2, or the CPU renderer. A line shows the mean and the p99 frame time of the last 120 frames. |
| 4 | Geometry X-ray | Medium | A toggle draws the boxes of each widget over the window, with the manager (`pack`, `grid`, `place`) and the grid cells. The page reads them with `winfo` and `grid info`. |
| 5 | Inspector | Medium | A click on a widget with the inspector on shows its path, its class, its manager, and its options. A change of an option in the table configures the widget and writes the option into the code. |
| 6 | Download your app | Low now, then the build of ztcl | The playground and the guided builds have a panel with Linux, macOS, and Windows, each on x86-64 and arm64. The platform of the reader is the first choice. A click gives a native binary of the code. See "Download your app". |
| 7 | Widget overview grid | Low | The page "Widgets" has one card for each widget, with its screenshot at one size, its name, and a link to its live snippet. |
| 8 | Classic and modern | Low | A toggle runs the snippet with the classic Tk look and with the ztk look. |
| 9 | Option tables as controls | Medium | The rows of an option table get a control: a number gets a slider, a color gets a color picker, and a choice gets a menu. |
| 10 | Stress button | Medium | A button adds 1,000 widgets or 10,000 rows to the demo and shows the frame time in the HUD. |
| 11 | Theme studio | Medium | A `ttk::style` editor restyles each snippet of the page and exports the style as Tcl. |
| 12 | Event strip | High | A strip lists each event of the window as it occurs, with its bind tags and its substitutions. ztk needs a hook in `src/web.zig` for it. |
| 13 | Guided builds | High | A tutorial in steps. Each step runs a test on the code of the reader and opens the next step. |
| 14 | Animation lab | High | An easing curve, a time scrubber, and slow motion for `ztk::animate`. ztk needs a clock hook in `src/web.zig` for it. |

## Download your app

The build of a native binary runs in the page, with no server. It uses the build core of ztcl (issue 40 and `docs/dev/static-build.md` of the ztcl repository): a runtime binary has a slot, and the build patches the slot and adds the code as a payload. For macOS the build also writes an ad hoc signature. That core is Zig code on byte slices, so it also runs in `ztcl.wasm`.

- The runtime of a ztk app is the `ztk` program of each target, with the same slot. The slot is a change in `src/main.zig` and goes to the owner of the program. The site serves the runtimes from its own origin, in `play/runtimes/`, with a file `play/runtimes/manifest.json` that lists each target, its file, its size, and its SHA-256 hash.
- The panel of the playground shows the six targets. The page reads the platform from `navigator.userAgentData` or from the user agent, and selects that target first.
- A click loads the runtime of the target, checks its hash, calls the build of the wasm module with the runtime, the code, and the target, and gives the reader the output file.
- The panel shows only when the manifest exists and the module has the build. Until then, `?download` in the URL shows the panel for a test, with a note that the build is not on the site yet.

The page calls the build through one function. When the build of ztcl lands, the function calls it, and the panel needs no other change. The API that the page expects goes into `docs/dev/static-build.md` of ztcl as a request.

## For the ztcl site

These go in a PR to the ztcl repository after the ztk items 1 to 3. They use the npm module of ztcl.

- A REPL in the page.
- Runnable examples, with the live snippet of ztk and no window.
- A step-limit meter.
- A view of the bytecode of a proc, if the module exports one.

## Limits

- A live snippet needs WebAssembly. A browser with no WebGPU and no WebGL 2 uses the CPU renderer.
- The inspector writes an option into the code only for a widget that the code makes with a literal path, for example `button .b -text Hi`.
- The text widget page comes from the task of the text widget. The live snippet works on it with no change.
