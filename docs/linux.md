# On Linux

ztk opens windows on Linux with its own client of the Wayland protocol, and with its own X11 client on a desktop with no Wayland compositor. Neither one links a C library, so the static Linux programs of a release open a window too. [Install](install.md#build-from-source) has the build.

## The backends

| Session | Backend | Renderer |
|---|---|---|
| Wayland (`WAYLAND_DISPLAY` is set) | The Wayland client of ztk (`src/platform/wl/`), with its own reader of the XKB key map | Vulkan into dma-bufs when the GPU and the compositor share them (`zwp_linux_dmabuf_v1` version 3, linear XBGR8888), else the CPU renderer into shared memory |
| X11 (`DISPLAY` is set, no `WAYLAND_DISPLAY`) | The X11 client of ztk (`src/platform/x11.zig`) | The CPU renderer with `PutImage` |
| No display | `ztk --headless`, or `ZTK_HEADLESS=1` for a bundled app | The CPU renderer, with no window |

With the CPU renderer on Wayland, ztk writes the cause to stderr once. `ZTK_RENDERER=cpu` or `--cpu` selects the CPU renderer. `ZTK_WAYLAND_DEBUG=1` prints each Wayland event.

## What works on Wayland

- The pointer shapes (`cursor-shape-v1`), the clipboard (`wl_data_device`), and the text of an input method (`text-input-v3`).
- Drops of files and text from other apps, and drags out of a window: [ztk::dnd](commands/dnd.md).
- Tray icons as StatusNotifierItems on the session bus: [ztk::tray](commands/tray.md). The item has no D-Bus menu yet, so a script posts its own menu.
- The file dialogs through the `FileChooser` portal, when the session bus has `org.freedesktop.portal.Desktop`. A desktop with no portal gets the dialogs that ztk renders.
- `wm attributes -fullscreen`. Wayland has no request for topmost, so ztk keeps the value of `-topmost` and sends nothing.
- Less motion from the portal settings of GNOME and KDE, as [Animation](animation.md#reduced-motion) describes.
- `wm iconphoto` with `xdg-toplevel-icon-v1`.

## What works on X11

The X11 client is a first version: one window, the keys with autorepeat, the buttons and the wheel, focus, resize, the close button, the title, the minimum size, and `wm iconphoto` (`_NET_WM_ICON`). It has no popups (ztk renders menus in the window), no clipboard, no input method, and no scale from `Xft.dpi` yet.

## Make an app

`ztk bundle -o notes --desktop --name "My Notes" --icon notes.png notes.tcl` writes one program with the scripts inside it, a desktop entry, and an icon. [Install](install.md) has the options of `ztk bundle`.

## Not on Linux yet

`ztk::taskbar`, `ztk::recent`, and `ztk::hotkey` give an error on Linux: [the platform table](commands/taskbar.md#platforms). `ztk::has` tells a script what this program has ([ztk::has](commands/tray.md#platform-features)).
