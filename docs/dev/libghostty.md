# WIP: libghostty-vt as the core of `ztk::terminal`

This page is the plan and the state of the move of the terminal core of `ztk::terminal` to libghostty-vt. The work is not done. The resume steps are at the end.

## Facts checked on 2026-11-26

- ztk, ztcl, and dockyard build with Zig 0.17.0 (ztk #125). libghostty-vt 1.0.x needs Zig 0.17, so the Zig version is no longer a blocker.
- The tag `vt-1.0.2` of github.com/ghostty-org/ghostty is commit `573c4a21e02311ae87844af26b6a7a179f82858e`. The SHA-256 of its GitHub source archive is `c5c138c4a5673999b6678a4c7b48791c195ea86376cbb2221460a826eeaa16fc`. Its `build.zig.zon` has `.minimum_zig_version = "0.17.0"`. The license is MIT.
- The build exports the Zig module `ghostty-vt` (`src/build/GhosttyZig.zig`, root `src/lib_vt.zig`). The module has `Terminal`, `Stream`, `RenderState`, `Cell`, `modes`, `sgr`, and `osc`. A Zig program uses `b.dependency("ghostty", ...).module("ghostty-vt")`, so ztk needs no C API and no prebuilt library.
- `zig build -Demit-lib-vt -Dsimd=false -Doptimize=ReleaseFast` in the source tree passes with Zig 0.17.0 on x86_64 Linux. With `-Dsimd=false` the module needs no libc and no C++ code (the build sets `link_libc` only when `simd` is on). The shared library is 11,284,640 bytes with `-Dsimd=false` and 11,696,448 bytes with SIMD, both unstripped.
- The build fetches its Zig packages from `deps.files.ghostty.org`. `uucode` (the Unicode tables) is the one package that the VT module always needs. The other packages of `build.zig.zon` are lazy and belong to the app.

## Not measured yet

- The parse speed of `-Dsimd=false` against SIMD on the bench of `src/term/`.
- The size of `zig-out/web/ztk.wasm` with the module, and whether the module builds for `wasm32-freestanding` inside ztk (its own CI builds a separate wasm module).
- The link of the module on Windows (msvc ABI) and macOS.

## Plan

1. Add `ghostty` to `build.zig.zon` at tag `vt-1.0.2` (`zig fetch --save=ghostty <archive URL>`), and pass `.simd = false` to `b.dependency`.
2. Write `src/term/ghostty.zig`: the interface that `widget.zig` uses today (`write`, `resize`, `lineAt`, `scrollbackLen`, the cursor, the modes, the dirty rows), on `Terminal` and `RenderState` of the module.
3. Select the core with a build option (`-Dterm-core=ztk|ghostty`, default `ztk`). Run the terminal tests on both cores.
4. Switch the default when the tests pass on Linux, macOS, Windows, and wasm32. Remove `src/term/parser.zig` and `src/term/screen.zig` in a follow-up PR.
5. Credit Ghostty (MIT, Mitchell Hashimoto and the Ghostty contributors) in `docs/references/terminal.md`, `docs/references/dependencies.md`, `npm/NOTICE`, and `licenses/`.

## Resume steps

1. Clone ztk, check out this branch, and rebase it on main.
2. Use Zig 0.17.0 with its own `ZIG_LOCAL_CACHE_DIR` and `ZIG_GLOBAL_CACHE_DIR`, under the 4 GB memory cap of AGENTS.md.
3. Do step 1 of the plan, then build `zig build test` and `zig build wasm`, and record the sizes and the times on this page.
4. Ask the user to approve the dependency before the merge: section 6 of `plan.md` lists no third-party library.
