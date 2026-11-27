# Wayland

The Wayland backend (`src/platform/wayland.zig`) has its own client of the protocol and its own reader of key maps. It links no library. This page lists the documents that the code follows.

## The protocol

| Source | License | Use |
|---|---|---|
| The section "Wire Format" of the Wayland protocol documentation (wayland.freedesktop.org) | MIT | The message header, the argument types, the padding, and file descriptors in `SCM_RIGHTS` (`src/platform/wl/wire.zig`) |
| `wayland.xml` (package `wayland`) | MIT | The requests, events, and enums of `wl_display`, `wl_registry`, `wl_compositor`, `wl_surface`, `wl_shm`, `wl_seat`, `wl_pointer`, `wl_keyboard`, and the data device |
| `stable/xdg-shell/xdg-shell.xml` | MIT | The toplevel, the popup, and the positioner |
| `unstable/xdg-decoration/xdg-decoration-unstable-v1.xml` | MIT | Server-side decorations |
| `stable/viewporter/viewporter.xml`, `staging/fractional-scale/fractional-scale-v1.xml` | MIT | The fractional scale |
| `staging/cursor-shape/cursor-shape-v1.xml` | MIT | The pointer shapes |
| `unstable/text-input/text-input-unstable-v3.xml` | MIT | The text of an input method |
| `stable/linux-dmabuf/linux-dmabuf-v1.xml` | MIT | The dma-buf buffers of the Vulkan path: the `modifier` event of version 3, `create_params`, `add`, and `create_immed` |

The XML files come from the packages `wayland` and `wayland-protocols`. The code has the opcodes and the enum values of the XML files as numbers. No code of `libwayland` went into ztk.

## Key maps

| Source | License | Use |
|---|---|---|
| The page of the keymap text format (version 1) in the xkbcommon documentation (xkbcommon.org) | MIT | The sections, the key types, the levels, and `modifier_map` (`src/platform/wl/xkb.zig`) |
| `keysymdef.h` of the X11 protocol headers (package `xorgproto`) | The license of The Open Group, a permissive license. Its notice is at the top of the output file. | `tools/gen-keysyms.py` makes `src/platform/wl/keysyms.zig`, the names of the key symbols and their Unicode code points |

`src/platform/wl/xkb.zig` does not read the compatibility section or the actions. The compositor sends the modifier state, so the client needs neither.
