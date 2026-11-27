# Zig 0.17.0

ztk builds with Zig 0.17.0 and with a ztcl that builds with Zig 0.17.0. The changes of the language and of the standard library are the same as in ztcl, and `docs/dev/zig-0.17.md` of ztcl lists them. This page lists the changes that only ztk has.

## Build

- `build.zig.zon` has `.minimum_zig_version = "0.17.0"`, and each CI workflow sets Zig 0.17.0.
- `@cImport` is gone. The C headers of a backend are in a header file, and the build translates the file into a module with `b.addTranslateC`:
  - `src/platform/wayland_c.h` is the module `wayland_c`. The translation gets the include folders of the `wayland-scanner` headers and the system libraries `wayland-client` and `xkbcommon`.
  - `src/render/vulkan_c.h` is the module `vulkan_c`. The translation gets the include folder of the pinned Vulkan headers.
- `b.build_root` is gone. The option `repo_root` comes from `opts.addOptionPathUntracked("repo_root", b.path("."))`.

## Code

- `std.builtin.Type.Fn.Param.Attributes` is `std.builtin.Type.Fn.ParamAttributes` (`src/sys/com.zig`). The parameters of a function type are in `param_types` (`src/sys/objc.zig`).
- The `objc` call helpers of `src/platform/appkit.zig` and `src/render/metal.zig` read `field_types` of `@typeInfo`.

## Checks

These checks ran on 2026-11-26 on an x86_64 Linux machine with 8 cores. They compare the branch with main built by Zig 0.16.0 on the same machine.

- `zig build test`: 639 of 640 tests pass (1 skipped) on the branch after a rebase on main, and 612 of 612 on main c2604a6 with Zig 0.16.0. The golden test `box-plain` reports 1 pixel with a difference of 16, within its tolerance. Zig 0.16.0 on main reports the same pixel. No golden file changed.
- The program builds for `x86_64-linux-musl` and `aarch64-linux-musl` (direct and headless), `x86_64-macos` and `aarch64-macos` (AppKit and headless), and `x86_64-windows` (headless, and the default backends). `zig build wasm` builds.
- `zig build bench -Doptimize=ReleaseFast`, two runs of each version, the lower median of each case: the medians are within 7 percent, except `vector-10000-drag` at 23 us against 19 us. The p99 values move by up to 30 percent in both directions between runs of one version, because other jobs used the machine. `build-1000` has a p99 above the budget of 8 ms with both versions (8,537 us with 0.17.0 and 9,142 us with 0.16.0).
