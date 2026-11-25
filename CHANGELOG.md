# Changelog

## Unreleased

- Adds the example apps `examples/spreadsheet.tcl` (10 000 rows on a canvas, with formulas) and `examples/vector.tcl` (a drawing tool with SVG export and a script console), their tests in `tests/apps.sh`, their bench cases, and their live cards on the site.
- Adds `ztk::limit`, the `interp` command, and `ztk::style scheme`.
- Adds the WebGPU renderer of the web build (`webgpu.js`). `"auto"` selects WebGPU, then WebGL 2, then the CPU renderer. The web canvas has the size of its window at each pixel ratio.

## v0.2.0-beta (2026-11-25)

- Adds the plan, the Stage 1 tasks, the review checklist, and the references.
- Adds the tools that measure the size of Tk.
- Adds the docs site, the CI and release workflows, and the Homebrew formula template.
- Licensed under BSD-2-Clause.
- Adds the npm package `@beetlebug/ztk`, with types, and a workflow that publishes it on a version tag. `ztk.js` has `mount`, a CPU renderer for a browser with no WebGL 2, and `destroy`. See `docs/web.md` and `docs/npm.md`.

