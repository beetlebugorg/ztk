# libghostty-vt as the core of `ztk::terminal`

`ztk::terminal` keeps its state in libghostty-vt 1.0.2 through `ztcl.vt.Term`, the binding of ztcl (module `ztcl::vt`). `src/term/core.zig` gives the widget the fields and the methods of the old `Screen`. The user approved the dependency on 2026-11-26 and asked for a static link on each target.

## Facts checked on 2026-11-26

- The tag `vt-1.0.2` of github.com/ghostty-org/ghostty is commit `573c4a21e02311ae87844af26b6a7a179f82858e`. The SHA-256 of its GitHub source archive is `c5c138c4a5673999b6678a4c7b48791c195ea86376cbb2221460a826eeaa16fc`. Its `build.zig.zon` has `.minimum_zig_version = "0.17.0"`. The license is MIT.
- ztcl pins the archive and gives the Zig module `ghostty-vt` to each of its modules with `-Dsimd=false`, `-Demit-lib-vt=true`, and `-Dvt-features=-kitty_graphics`. With these options the module has no C code, no C++ code, and no libc. The Kitty graphics feature compiles the C code of wuffs, which needs `calloc` and `free`. ztk gets the module through the dependency `ztcl`, so ztk has no dependency of its own on Ghostty.
- The build makes no shared library. The module is Zig code in each program.
- `src/main.zig` writes only the log of the default scope, and `src/web.zig` drops the log, since libghostty-vt logs the sequences that it does not handle.

## Measurements

These ran on 2026-11-26 on an x86_64 Linux machine with 8 cores, with Zig 0.17.0, while other builds used the machine.

- `zig build term-bench` (`src/term/bench.zig`, ReleaseFast, best of 5 runs, 8,388,627 bytes of generated output in chunks of 4 KiB on 80 by 24 cells): `screen.zig` 69.7 ms (114.7 MiB/s), libghostty-vt 56.5 ms (141.6 MiB/s). A second run gave 70.4 ms and 57.5 ms.
- `zig build wasm`: `zig-out/web/ztk.wasm` is 5,462,782 bytes on main 14b29f4 (ztcl d284072) and 6,058,605 bytes on this branch (ztcl d63adc1), +595,823 bytes. The difference has libghostty-vt, the Tcl command `ztcl::vt`, and the other changes of ztcl between the two commits. In ztcl itself, `ztcl.wasm` is 477,168 bytes larger with `ztcl::vt` than with `-Dmod-vt=false` (ztcl #168). The branch has no copy of `parser.zig` and `screen.zig` in the wasm file, since the widget does not import them.
- `zig build test`: the 5 tests of `src/tests/terminal.zig` pass on the new core with no change to a test or a golden file.

## Not done

- The follow-up PR removed `src/term/parser.zig`, `src/term/screen.zig`, `src/term/width.zig`, and `zig build term-bench`.
- The replies of DA (`ESC [c` gives `ESC [?62;22c`), DSR, and the OSC color queries 10 and 11 (black on white, as the old `Screen.theme`) come from `ztcl.vt.Term`. A check with `ztcl::vt feed` gave each reply on 2026-11-26.
- The cursor style of DECSCUSR comes from libghostty-vt: 1 or 2 is a block, 3 or 4 an underline, and 5 or 6 a bar.
