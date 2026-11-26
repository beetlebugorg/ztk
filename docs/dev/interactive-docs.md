# Interactive docs

The user asked on 2026-11-25 that the docs site be very interactive. The user then changed the aim on the same day: the reader is often an agent, and the person describes an app, watches it get built, judges it, and ships it. The headline of the site is "the GUI toolkit AI can see": `ztk::snapshot`, `ztk::tree`, and `ztk::inject` let an agent see and drive the window that it builds. This file is the design and the order of the work. Each item is one PR, and each PR is live on beetlebug.org/ztk after the merge.

## The site, outcome first

| Part | What the reader gets |
|---|---|
| See it | Live apps, the widget grid, the stress button, and the frame time, in the reader's browser. |
| Ask for it | A description of an app, and a replay of an agent that builds it, step by step. |
| Trust it | What an app can do, first: the capabilities of ztcl, the sandbox, and the short Tcl code that a person can audit. |
| Ship it | A native binary for the reader's platform (see "Download your app"). |
| Look inside | The code, the inspector, X-ray, the theme, and later the event view and the theme studio. These are the tools a person uses to check what an agent built. They are not the headline. |

## The list, ranked

| Rank | Item | Cost | State |
|---|---|---|---|
| 1 | `llms.txt` and `llms-full.txt` for ztk and ztcl: the page list and the full text of the docs, for an agent. | Low | Next |
| 2 | An API index in JSON: each command, each widget class, and its options with the defaults, made by ztk itself in CI, so the index matches the code. | Low | Next |
| 3 | A skill for agents that build ztk apps: the API, the idioms, and the loop of `ztk::snapshot`, `ztk::tree`, and `ztk::inject`. | Medium | Next |
| 4 | Examples that CI runs, so an agent learns only patterns that work. The snippets of the widget pages run in `tests/docs-live.sh` today. | Low | Part done |
| 5 | The live snippet: the window runs the code as the reader types, with Reset, a playground link, a renderer menu, and the frame time. | Low | Done (#108) |
| 6 | A live snippet and a shot for each widget, and the widget grid. | Low | #111 |
| 7 | Look inside: X-ray, Inspect (an option change goes into the code), the theme menu, and the stress button. The hero of the landing page is a live snippet. | Medium | #112 |
| 8 | Download your app: the panel in the playground. | Low now, then the build of ztcl | #112, waits for ztcl issue 40 |
| 9 | Watch it get built: a replay player for a recorded session of dockyard. See "Replay". | Medium | Design |
| 10 | Trust it: a page that shows the capabilities of an app before its code, from the flags of `ztk` and the limits of ztcl. | Medium | Later |
| 11 | Option tables as controls, the theme studio, the event strip, and the animation lab. | Medium to high | Later |
| 12 | dockyard in the browser with the reader's own agent. See "Later". | High | Design only |

## Replay

A recording is a JSON file: `{"version": 1, "title": "...", "steps": [...]}`. Each step has `say` (the text of the person or of the agent, with `who`), and can have `script` (the full Tcl text of the app after the step) and `checks` (the result of `ztk::tree` or a shot that the agent used). The player shows the chat on one side and the app of the selected step on the other. A scrub to a step runs its script in a live snippet, so the app is live and can get clicks. The player makes no API call. The format goes to the dockyard repository for review, and dockyard writes it when it records a session. Until then, the site has one or two recordings that a person writes by hand.

## Later: dockyard in the browser

The page connects the reader's own agent: a coding agent on the reader's computer through an MCP bridge, or the reader's API key in the page. The agent gets the tools of a live snippet: run a script, `ztk::snapshot`, `ztk::tree`, and `ztk::inject`. This is a design only. It needs a review of the keys and the permissions first.

## Download your app

The build of a native binary runs in the page, with no server. It uses the build core of ztcl (issue 40 and `docs/dev/static-build.md` of the ztcl repository): a runtime binary has a slot, and the build patches the slot and adds the code as a payload. For macOS the build also writes an ad hoc signature. That core is Zig code on byte slices, so it also runs in `ztcl.wasm`.

- The runtime of a ztk app is the `ztk` program of each target, with the same slot (`src/appbin.zig`). `web/ztcl-build.js` runs the build in a second instance of `ztk.wasm`. The panel stays hidden until a job builds the `ztk` program of each target for the site. The site serves the runtimes from its own origin, in `play/runtimes/`, with a file `play/runtimes/manifest.json` that lists each target, its file, its size, and its SHA-256 hash.
- The panel of the playground shows the six targets. The page reads the platform from `navigator.userAgentData` or from the user agent, and selects that target first.
- A click loads the runtime of the target, checks its hash, calls the build of the wasm module with the runtime, the code, and the target, and gives the reader the output file.
- The panel shows only when the manifest exists and the module has the build. Until then, `?download` in the URL shows the panel for a test, with a note that the build is not on the site yet.

The page calls the build through one function. When the build of ztcl lands, the function calls it, and the panel needs no other change. The API that the page expects goes into `docs/dev/static-build.md` of ztcl as a request.

## For the ztcl site

These go in PRs to the ztcl repository. They use the wasm module of ztcl.

1. The shell in the page. It is the real shell of ztcl (ztcl issues 4 and 75): the line editor with the vim mode, the history, the completion, the syntax colors, and the key that opens the line in an editor. The wasm module gets the line editor and a terminal hook: raw key bytes go in, and ANSI text comes out. A terminal in the page shows it. The first choice is the VT core of ztk (`src/term/`, the core of `ztk::terminal`) in a web build. If that core is not ready, a small terminal library at a fixed version shows it. The editor key opens an editor in the page and gives the text back to the line. The landing page gets a shell at the top, and a page of its own gets a full-size shell. Each shell has no capability of ztcl and shows the compute limit as a meter.
2. Runnable examples, with the live snippet of ztk and no window.
3. A view of the bytecode of a proc, its tier, and its compute units, if the module exports them.
4. A race: the same proc in the interpreter and as compiled wasm.

## Limits

- A live snippet needs WebAssembly. A browser with no WebGPU and no WebGL 2 uses the CPU renderer.
- The inspector writes an option into the code only for a widget that the code makes with a literal path, for example `button .b -text Hi`.
- The text widget page comes from the task of the text widget. The live snippet works on it with no change.
