# Dependencies

The rule of the plan: ztk needs only the interfaces of the platform, ztcl, and the Zig standard library. Section 6 of [the plan](../plan.md) has the table for each platform. The license names of the system libraries are from the package data of the development machine on 2026-11-23. A task that first links a library checks the license file and adds its text to `licenses/`.

## Linked into ztk

| Library | Use | License | Stage |
|---|---|---|---|
| ztcl | The Tcl interpreter | BSD-2-Clause | 1 |
| Zig standard library | All | MIT | 1 |
| libwayland-client | The Wayland protocol, only in the Wayland backend | MIT | 1 |
| libxkbcommon | Key maps, only in the Wayland and X11 backends | MIT | 1 |
| libxcb | X11, only in the X11 backend | X11 license | 2 |

## Opened at run time, optional

| Library | Use | License | Stage |
|---|---|---|---|
| Vulkan loader | The GPU on Linux | Apache-2.0 | 1 |
| fontconfig | The font choices of the user on Linux | HPND | 2 |
| HarfBuzz | Shaping of complex scripts | "Old MIT" | 4 |
| AccessKit | Accessibility adapters | MIT OR Apache-2.0 | 8 |

## Data in ztk

| Data | Use | License | Stage |
|---|---|---|---|
| Inter 4.1 (in `assets/fonts/`) | The fallback font and the font of the tests | SIL Open Font License 1.1 | 1 |

The license of Inter was read in `LICENSE.txt` of its release archive 4.1, and the file is `assets/fonts/LICENSE-Inter.txt`. The files `Inter-Regular.ttf` and `Inter-Bold.ttf` come from `extras/ttf/` of that archive. https://github.com/rsms/inter

## Build tools and headers

| Tool | Use | License |
|---|---|---|
| Vulkan-Headers | The declarations of Vulkan | Apache-2.0 OR MIT |
| Linux kernel headers (`linux/fb.h`, `linux/input.h`, `linux/kd.h`, `linux/vt.h`) | The numbers and the structures of the kernel interfaces of the direct backend. ztk writes its own declarations in Zig. | GPL-2.0 WITH Linux-syscall-note |
| `glslc` (shaderc) | Compiles the shaders | Apache-2.0 |
| `wayland-scanner`, `wayland-protocols` | Makes the protocol code | MIT |

The license of the Vulkan headers was read in `LICENSE.md` of https://github.com/KhronosGroup/Vulkan-Headers. The license of AccessKit was read in its README and its `Cargo.toml`. https://github.com/AccessKit/accesskit

The kernel interface headers have a note that permits a program to use the system call interface with no effect on the license of the program. The implementer checks the first line of each header (`SPDX-License-Identifier`) before the task that uses it.

## Test tools

`wish` and `tclsh` 8.6.16, `Xvfb`, `weston`, and the Python package `fontTools` run tests. They are not linked.

## Vulkan-Headers (pinned package)

`build.zig.zon` pins `git+https://github.com/KhronosGroup/Vulkan-Headers` at the tag `v1.4.369` (commit `d277a0a3cda9c682708c93279f0c72cd6b0ae3f3`, the newest tag on 2026-11-23). `src/render/vulkan.zig` reads `vulkan/vulkan.h` with `@cImport`. The program does not link the Vulkan loader: it opens `libvulkan.so.1` at run time. The license is "Apache-2.0 OR MIT".

## glslc (build tool)

`build.zig` runs `glslc` (package `shaderc`) to compile the two shaders. The SPIR-V files are build outputs and are not in the repository. A machine with no `glslc` cannot build the Vulkan renderer. The option `-Dvulkan=false` leaves the renderer and the shaders out.

## The Wayland backend (task 17)

`libwayland-client` and `libxkbcommon` link into the program through `pkg-config`. `wayland-scanner` (build tool) makes the C code of the protocols `xdg-shell`, `xdg-decoration-unstable-v1`, `viewporter`, `fractional-scale-v1`, `tablet-v2` (needed by `cursor-shape-v1`), and `cursor-shape-v1` from the files in the folder of the package `wayland-protocols`. Both libraries have the MIT license, and the protocol files have the MIT license too. `src/platform/wayland.zig` is the only file that imports their headers. The build option `-Dbackends=direct,headless` leaves the backend out.
