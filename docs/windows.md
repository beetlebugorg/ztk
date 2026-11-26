# On Windows

ztk has a native backend for Windows 10 and 11. It uses Win32 for the windows and the input, and Direct3D 12 for the drawing, with no layer between ztk and Windows.

## Build and run

Install [Zig 0.16.0](https://ziglang.org/download/). The build needs no other tool: the shaders compile at run time with the shader compiler that Windows has.

```sh
git clone https://github.com/beetlebugorg/ztk
cd ztk
zig build -Doptimize=ReleaseFast        # makes zig-out\bin\ztk.exe
zig-out\bin\ztk.exe examples\demo.tcl   # opens a window
```

`ztk --headless` works as on the other systems, with no window.

The variable `ZTK_RENDERER` picks the output of the window:

| Value | Output |
|---|---|
| (not set) | Direct3D 12, and the CPU renderer when the machine has no Direct3D 12 device |
| `d3d12` | Direct3D 12 only. The program stops when no device exists. |
| `warp` | Direct3D 12 on WARP, the software rasterizer of Windows |
| `cpu` | The CPU renderer, with `SetDIBitsToDevice` |

## What works

- Windows: a window for each toplevel, with its title and size, the close button, and the focus.
- Scale: each window has the scale of its monitor (per-monitor DPI), and the scale changes when the window moves to another monitor.
- Drawing: Direct3D 12 on the first hardware GPU, then WARP. In the tests, each test scene equals the image of the CPU renderer within 2 levels in a channel.
- Keys: the keysyms of Tk, the text of each key, and the modifiers Shift, Control, Alt, and the Windows key. Alt+F4 closes the window.
- Pointer: motion, the buttons 1, 2, and 3, the two side buttons as 8 and 9, the wheel in both directions, and the cursor of each widget (`-cursor` and the CSS `cursor`).
- Input methods: the Text Services Framework. The text of an input method goes into an entry or a spinbox.
- Clipboard: `clipboard` and the copy and paste of an entry use the clipboard of Windows, as Unicode text.
- Global shortcuts: `ztk::hotkey add <Control-Alt-k> script` runs the script when the keys go down in any app, with `RegisterHotKey`. It needs `--allow hotkey`, and a shortcut that another app has is an error.
- Dark mode: with no `--dark`, ztk follows the dark mode of Windows, also when it changes while the program runs.
- Menus: the `-menu` of a toplevel is a menu bar of Windows, and `tk_popup` shows a menu of Windows. Alt and F10 open the bar.
- Tray: `ztk::tray` shows an icon in the notification area, with its tooltip, its clicks, and its menu.
- File dialogs: `tk_getOpenFile`, `tk_getSaveFile`, and `tk_chooseDirectory` show the dialogs of Windows, with the options of Tk. They need the file capability of ztcl, which the `ztk` program turns on by default and a program that embeds ztk grants.

## Limits

- No input method has typed into ztk on a real desktop yet. The tests drive the text store of ztk the way an input method does.
- The entry does not show the text that an input method composes. The input method shows its list of choices next to the entry.
- The clipboard code has not run in a test with success, because the test machines gave the tests no clipboard access.
- The frames come at 60 each second, also on a monitor with a faster refresh.
- While a window moves or changes size, it shows its last frame until the move ends.
- The menus of Windows have the light look, also in dark mode.
- Notifications are not done yet.
- The accent color of Windows is not in the themes yet.

The design and the plan are in [docs/dev/windows.md](https://github.com/beetlebugorg/ztk/blob/main/docs/dev/windows.md).
