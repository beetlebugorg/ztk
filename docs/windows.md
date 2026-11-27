# On Windows

ztk has a native backend for Windows 10 and 11. It uses Win32 for the windows and the input, and Direct3D 12 for the drawing, with no layer between ztk and Windows.

## Build and run

Install [Zig 0.17.0](https://ziglang.org/download/). The build needs no other tool: the shaders compile at run time with the shader compiler that Windows has.

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
- Window icon: `wm iconphoto .w $photo` gives the window its small icon (the title bar and Alt+Tab) and its big icon (the taskbar), each one from the photo nearest to the size of the system at the DPI of the window. With `-default` the photos go to each toplevel made after the call too. Several photos of different sizes give the sharpest icons.
- Drawing: Direct3D 12 on the first hardware GPU, then WARP. In the tests, each test scene equals the image of the CPU renderer within 2 levels in a channel.
- Text: DirectWrite with the fonts of Windows. The default font is Segoe UI Variable with the optical size of each text size (Segoe UI on Windows 10), `monospace` is Cascadia Mono, and the glyphs have the grayscale antialiasing of Windows 11 apps.
- Look: the controls have the Fluent look of Windows 11 from the theme resources of WinUI 3 (shapes, strokes, fills, sizes, and the accent of the system), in light and dark. See `src/themes/fluent-windows.css`.
- Keys: the keysyms of Tk, the text of each key, and the modifiers Shift, Control, Alt, and the Windows key. Alt+F4 closes the window.
- Pointer: motion, the buttons 1, 2, and 3, the two side buttons as 8 and 9, the wheel in both directions, and the cursor of each widget (`-cursor` and the CSS `cursor`).
- Input methods: the Text Services Framework. The text of an input method goes into an entry or a spinbox.
- Clipboard: `clipboard` and the copy and paste of an entry use the clipboard of Windows, as Unicode text.
- Taskbar: `ztk::taskbar progress` shows a value, a paused or failed value, or a progress with no value on the taskbar button of `.`. `ztk::taskbar badge count` shows the count on a red disc over the icon, and `ztk::taskbar attention` flashes the button.
- Recent documents: `ztk::recent add path` puts a file in the recent items of Windows and in the jump list of the app, when the app opens files of that type. `ztk::recent clear` empties the jump list of the app. `add` needs the real paths of the host, the default of the `ztk` program.
- Global shortcuts: `ztk::hotkey add <Control-Alt-k> script` runs the script when the keys go down in any app, with `RegisterHotKey`. It needs `--allow hotkey`, and a shortcut that another app has is an error.
- Drops from other apps: `tkdnd::drop_target register .w {DND_Files DND_Text}` lets Explorer and other apps drop files or text on `.w`, through OLE. `<<Drop>>` gets the data in `%D`: a list of the paths, or the text. `<<DropEnter>>`, `<<DropPosition>>`, and `<<DropLeave>>` follow the drag. A drag out: `ztk::dnd drag .w -files [list $path]` (or `-text`) from a `<B1-Motion>` binding runs the drag of Windows, and gives `copy`, `move` (with `-move 1`), or `none`.
- Dark mode: with no `--dark`, ztk follows the dark mode of Windows, also when it changes while the program runs. The title bar and the frame of each window follow the scheme of the app.
- Menus: the `-menu` of a toplevel is a menu bar of Windows, and `tk_popup` shows a menu of Windows. Alt and F10 open the bar.
- Tray: `ztk::tray` shows an icon in the notification area, with its tooltip, its clicks, and its menu.
- File dialogs: `tk_getOpenFile`, `tk_getSaveFile`, and `tk_chooseDirectory` show the dialogs of Windows, with the options of Tk. They need the file capability of ztcl, which the `ztk` program turns on by default and a program that embeds ztk grants.

## Limits

- The text is shaped by DirectWrite on one font: a character that the font lacks shows as its missing glyph, because font fallback is not done yet, and right-to-left text keeps the order of the characters. The glyph images do not have the contrast and gamma of the system yet.

- No input method has typed into ztk on a real desktop yet. The tests drive the text store of ztk the way an input method does.
- The entry does not show the text that an input method composes. The input method shows its list of choices next to the entry.
- The clipboard code has not run in a test with success, because the test machines gave the tests no clipboard access.
- The frames come at 60 each second, also on a monitor with a faster refresh.
- While a window moves or changes size, it shows its last frame until the move ends.
- The menus of Windows have the light look, also in dark mode.
- Notifications are not done yet.
- The accent color of Windows is not in the themes yet.

The design and the plan are in [docs/dev/windows.md](https://github.com/beetlebugorg/ztk/blob/main/docs/dev/windows.md).
