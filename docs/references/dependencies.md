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
| Inter 4.1 (proposed) | The fallback font and the font of the tests | SIL Open Font License 1.1 | 1 |

The license of Inter was read in `LICENSE.txt` of its repository, tag `v4.1`. https://github.com/rsms/inter

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
