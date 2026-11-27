# The Windows backend

This page is the plan for the native Windows backend: Win32 for the windows, the input, the input method, the clipboard, the cursors, and the per-monitor scale, and Direct3D 12 for the drawing. Section 4.12 of [the plan](plan.md) names this pair, and decision D3 rules out a translation layer. The backend fills the platform interface of [the macOS plan](macos.md) with no change to it. The work is in `src/platform/`, `src/render/`, and `src/sys/`. It does not change the widgets.

## Where ztk is on Windows

Measured on 2026-11-25 on an x64 PC with Windows 11 (build 26200) and Zig 0.16.0:

- `zig build` builds `zig-out/bin/ztk.exe` with the headless backend only.
- `zig build test` did not compile, for two reasons. `tests/vulkan.zig` was imported in each build (the macOS PR 2 fixes it), and `std.testing.environ.getPosix` does not exist on Windows. `src/testing.zig` and `src/tests/scene.zig` call it.
- `ztk::style load` failed for each file with `OutsideStyleFolder`. `App.readFile` checks for a `/` after the real path of the style folder, and a real path on Windows has `\`. 16 tests failed for this reason.
- `ztk --headless t.tcl | cat` did not print the output of `puts`. The writer of the standard output is positional, and a positional write to a pipe fails on Windows. With a file as the output, `puts` worked.
- The test `host: the clock moves forward across a sleep` failed in 1 of 3 full runs. A sleep on Windows can end before `nowUs` moved by the time of the sleep, so `sleepUs` now sleeps again for the rest.
- With the fixes of PR 1, `zig build test --summary all` passes 451 of 451 tests in 1 minute on the base of the macOS PR 2 (Debug, in a Job Object with a limit of 4 GB).

## The PRs

| # | PR | Tests |
|---|---|---|
| 1 | This plan, the fixes above, and a CI job on `windows-latest` | `zig build test` and the headless script on Windows in CI |
| 2 | `src/platform/win32.zig`: the Win32 functions that ztk calls | Unit tests that make a window class and a hidden window |
| 3 | `src/render/d3d12_api.zig` (the COM interfaces that ztk calls) and the Direct3D 12 renderer, offscreen | Each golden scene drawn by Direct3D 12 equals the CPU image within the tolerance of the Vulkan tests |
| 4 | The Win32 backend: windows, the event loop, the frame clock, the scale, and a swapchain target. The CPU output with `SetDIBitsToDevice` when no Direct3D 12 device exists. | Window tests that run only with `ZTK_TEST_WINDOWS=1` |
| 5 | Keyboard, pointer, wheel, and cursors (`setCursor`) | Unit tests of the key and modifier maps from recorded messages |
| 6 | The clipboard of the system (`clipboardGet`, `clipboardSet`) | Core tests with the clipboard of the headless backend, and a round trip of `CF_UNICODETEXT` with `ZTK_TEST_CLIPBOARD=1` in a process that has clipboard access |
| 7 | Input methods with the Text Services Framework (`textInput`, `preedit`, `commit`) | Unit tests that call the text store with the calls of an input method, and check the events |
| 8 | The dark mode and the accent color (`appearance`) | Unit tests of the registry values and of `WM_SETTINGCHANGE` |

PR 6 and PR 7 use the entries and the events that the macOS PRs 7 and 8 add. Whichever backend is first adds them to `src/platform/platform.zig` and `src/event.zig`.

## The platform interface on Windows

| Entry | Windows |
|---|---|
| `setCursor(window, shape)` | `LoadCursorW` with the `IDC_` shapes, and `SetCursor` on `WM_SETCURSOR` in the client area |
| `clipboardGet(type)`, `clipboardSet(type, data)` | `OpenClipboard` with `CF_UNICODETEXT`, and the UTF-16 conversion of the standard library |
| `textInput(window, on, rect)` | `ITfThreadMgr::AssociateFocus` with the document of the window for `on`, and the rectangle that `ITextStoreACP2::GetTextExt` gives for `rect` |
| `appearance()` | `AppsUseLightTheme` under `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`, and `DwmGetColorizationColor` |

Input methods use the Text Services Framework (TSF), by the decision of the user (2026-11-25). At start, the UI thread calls `CoInitializeEx` for a single-threaded apartment, makes the thread manager (`CLSID_TF_ThreadMgr`), and calls `Activate`. Each window has a document manager with one context. The context gets a text store of ztk, a COM object in Zig that implements `ITextStoreACP2` and `ITfContextOwnerCompositionSink`. The store has the text of the current composition only. `OnStartComposition` and `OnUpdateComposition` give `preedit` with the text of the composition range and the caret in it. `OnEndComposition` gives `commit` with the text that the input method left, and the store then empties. `GetTextExt` gives the rectangle of `textInput` (the box of the text widget), and `GetScreenExt` the client area of the window, in screen pixels, so the candidate window shows next to the widget. `textInput` comes from `src/textinput.zig`, which gives the backend the text widget with the focus after each flush. A `commit` event becomes one key press and release for each character, so the bindings of the entry insert it. The DLLs are `ole32` and `msctf`, both parts of Windows.

## The event loop

Win32 gives the messages of a window only to the thread that made it. The UI thread of ztk makes the windows, so the backend is a plain `Platform`:

- The program sets the awareness `PER_MONITOR_AWARE_V2` with `SetProcessDpiAwarenessContext` before the first window.
- The window procedure turns each message into an `Event` and appends it to the queue of the backend. `wait(timeout)` calls `MsgWaitForMultipleObjectsEx` with the timeout and the frame handle of each window. `poll` empties the message queue with `PeekMessageW`, `TranslateMessage`, and `DispatchMessageW`, and moves the queue to `out`.
- `WM_KEYDOWN` gives the keysym from a map of virtual keys, and the `WM_CHAR` that follows gives the text of that key. The two join in one `key` event. A surrogate pair joins before the event.
- `WM_MOUSEWHEEL` and `WM_MOUSEHWHEEL` give `scroll` events, with 120 units for one step of the wheel. A touchpad gives smaller units.
- The pointer messages call `Window.feedPointer` too.
- The scale is `GetDpiForWindow / 96`. `WM_DPICHANGED` gives a `scale` event, and the backend moves the window to the rectangle that the message suggests.
- The frame clock is a high-resolution waitable timer with a manual reset. `requestFrame` arms it for one frame time (16,667 microseconds) after the last tick, and the tick gives one `frame` event for each window that asked for one. The render thread presents with a sync interval of 1, so the swapchain follows the refresh of the display. The waitable object of the swapchain (`GetFrameLatencyWaitableObject`) and the refresh rate of the monitor can replace the fixed time in a later PR.

## The Direct3D 12 renderer

`src/render/d3d12.zig` fills the `Renderer` interface, with the design of the Vulkan renderer:

- One `Quad` is one instance. The vertex shader makes the four corners of a triangle strip. One draw call draws each atlas page.
- The instance buffer is in an upload heap. It grows by a factor of two. The render thread waits on a fence for the frame before it writes the buffer again.
- The atlas page is an `R8_UNORM` texture. It uploads again when the generation of the atlas changes.
- The shaders are HLSL source, a port of `quad.vert` and `quad.frag`, with the same formulas as `renderer.zig`. The renderer compiles the source at start with `D3DCompile` from `d3dcompiler_47.dll`, a part of Windows, so the build needs no shader compiler and a cross build from Linux works.
- Colors blend in sRGB space, as the CPU renderer and CSS do. The target format is `R8G8B8A8_UNORM`.
- The window target is a flip-model swapchain (`DXGI_SWAP_EFFECT_FLIP_DISCARD`) with two buffers. The render thread draws and presents. Direct3D 12 works from a thread other than the thread of the window.
- The offscreen target is a texture. The tests read it back and compare it with the CPU image of the same scene.
- The device is on the first hardware adapter of `IDXGIFactory6::EnumAdapterByGpuPreference`. With no hardware adapter, it is on the WARP adapter. With no device at all, `init` gives `error.NoD3D12`, and the backend uses the CPU renderer with `SetDIBitsToDevice` for the rows that changed.

## Menus

The backend fills the native menus of [menus.md](menus.md) with `src/platform/winmenu.zig`:

- Each `MenuId` is one popup `HMENU`. `menuSet` removes its items with `RemoveMenu` and inserts the entries again with `InsertMenuItemW`, so the handle stays the same in each cascade and bar that has it. A check entry has `MFS_CHECKED`, a radio entry also `MFT_RADIOCHECK`, a disabled entry `MFS_GRAYED`, and `column_break` is `MFT_MENUBARBREAK`. The text has each `&` doubled, a `&` before the underlined character, and the accelerator after a tab.
- Each menu has the style `MNS_NOTIFYBYPOS`, so a choice arrives as `WM_MENUCOMMAND` with the position of the item and the handle of its menu, and the position is the index of the entry. The backend queues it as a `menu` event with `invoke`.
- `setMenuBar` builds a bar with `CreateMenu` from the entries of the menu, sets it with `SetMenu`, and keeps the client size of the window. The menu with the role `help` has `MFT_RIGHTJUSTIFY`, at the right end of the bar. `DestroyWindow` destroys the menu of a window, so the backend removes the bar first.
- `WM_INITMENUPOPUP` calls the handler of the core with `opening`, and `WM_MENUSELECT` with `select`, inside the menu loop. `WM_UNINITMENUPOPUP` queues `closed`.
- `postMenu` runs `TrackPopupMenuEx`, which returns after the menu closed. The hint of an entry at the point has no effect. `unpostMenu` calls `EndMenu`.
- With a bar, Alt, F10, and the `WM_SYSCHAR` of an Alt key go on to `DefWindowProc`, which opens the bar or the menu of a mnemonic. The core still gets the key event of the press.
- The system draws the menus with the light look, also in the dark scheme.

## Tray

`ztk::tray` (ztk#54, `docs/dev/platform-features.md`) shows an icon in the notification area with `src/platform/wintray.zig`:

- `Shell_NotifyIconW` with `NOTIFYICON_VERSION_4`, and the window of `.` as the owner. The icon is an `HICON` from the RGBA pixels of the photo, made with a DIB section and `CreateIconIndirect`. A tray with no photo has the icon of an application of the system. The tooltip has 127 UTF-16 units at most.
- The shell sends the actions to the owner window: `NIN_SELECT` and `NIN_KEYSELECT` give `click`, `WM_LBUTTONDBLCLK` gives `double`, and `WM_CONTEXTMENU` gives `menu`. For `menu`, a tray with a menu shows it with `TrackPopupMenuEx` at the point of the pointer, after `SetForegroundWindow`, and posts `WM_NULL` after it, as the documentation of `TrackPopupMenu` asks.
- Explorer sends "TaskbarCreated" after it starts again, and the backend adds each icon again.
- The flag `template` is for macOS and has no effect on Windows.
- The tray test shows a real icon in the notification area, so it runs only with `ZTK_TEST_TRAY=1`, which the Windows job of CI sets.

## File dialogs

`tk_getOpenFile`, `tk_getSaveFile`, and `tk_chooseDirectory` (ztk#57, `docs/dev/platform-features.md`) run the Common Item Dialog of Windows with `src/platform/windialog.zig`:

- `IFileOpenDialog` for an open and a folder (`FOS_PICKFOLDERS`), and `IFileSaveDialog` for a save, with `FOS_FORCEFILESYSTEM` and `FOS_NOCHANGEDIR`. An open has `FOS_FILEMUSTEXIST` and, with `-multiple`, `FOS_ALLOWMULTISELECT`. A save has `FOS_OVERWRITEPROMPT` unless `-confirmoverwrite 0`.
- `-filetypes` becomes `SetFileTypes` with `*.txt;*.tcl` for each filter, and the index of `GetFileTypeIndex` sets `-typevariable`. `-initialdir` is an item of `SHCreateItemFromParsingName` for `SetFolder`.
- `Show` with the window of `-parent` (or `.`) as the owner runs the dialog to its end. The paths of `SIGDN_FILESYSPATH` come back with `/` between the parts, as Tk gives them. A cancel gives an empty string.
- The test of the backend configures each kind of dialog and reads its options back with no `Show`, so no dialog opens on the desktop.

## The color dialog and the message box

`tk_chooseColor` and `tk_messageBox` run the dialogs of Windows with `src/platform/winbox.zig`:

- `ChooseColorW` of comdlg32, with `CC_RGBINIT` for `-initialcolor`, `CC_FULLOPEN`, and `CC_ANYCOLOR`. The structure has no title, so a hook sets the title of `-title` in `WM_INITDIALOG`. The 16 custom colors stay for the life of the process. A cancel gives an empty string.
- `MessageBoxW` with the buttons of `-type`, the icon of `-icon`, and the default button of `-default` by its place in the type. The text is `-message`, then `-detail` after an empty line. A box with no owner window is modal to the thread (`MB_TASKMODAL`). Escape and the Close button give `cancel`, or `ok` for the type `ok`. The types `yesno` and `abortretryignore` have no Close button there, and Escape does no work, where the box that ztk draws gives `no` or `abort`.
- `MessageBoxW` needs no manifest. `TaskDialogIndirect` gives the detail a line of its own, and needs version 6 of the common controls, which only a bundled app has (`src/peres.zig`).
- The tests map the options onto the structures with no call, so no dialog opens on the desktop.

## CI

A `test-windows` job on `windows-latest` runs `zig build`, `zig build test`, and the headless script of the Linux job. From PR 3 on, the Direct3D 12 tests run on the WARP adapter of the runner, or print `SKIP:` with the reason.

## Rules for the tests

Rule 12 of `AGENTS.md` forbids windows on the live desktop session of the development machine. The Direct3D 12 tests draw offscreen. The tests of PR 2 make a window with no `WS_VISIBLE` and never show it. The window tests of PR 4 run only with `ZTK_TEST_WINDOWS=1`, which CI sets.

## Limits

- `DefWindowProc` runs its own message loop while a person moves or sizes a window. The UI thread does not return to the loop of the App in that time, so the window shows its last frame until the move ends. A timer during `WM_ENTERSIZEMOVE` can run the loop of the App, in a later PR.
- The frame clock has 60 ticks in each second on each monitor, also on a monitor with a higher refresh rate.
- The pointer positions reach the render thread from the UI thread only, so a drag that the render thread moves stops while the UI thread is busy.
- The entry does not draw the composition text yet. The `preedit` event keeps it in `app.text_input` for the widget code, and the candidate window of the input method shows the choices.
- The candidate window shows at the box of the text widget. The caret position is known only to the paint code of the entry.
- The clipboard code of PR 6 has not run with success: the development machine and the CI runner give the test process no clipboard access.
- The themes do not use the accent color of the system yet. `app.accent` has it.
- The fonts of the system (DirectWrite) and the accessibility tree (UI Automation) are not part of this plan.

## Decisions

- The input method is TSF from its first PR. The user decided this on 2026-11-25.

## Decisions for the user

1. The default backend of `ztk` on Windows. The recommendation is Win32, and the headless backend with `--headless` and in CI, as on Linux and macOS.

## Window state

`wm attributes -fullscreen` and `-topmost` (ztk#68) go to `src/platform/winstate.zig`. Full screen gives the window the style `WS_POPUP` with no frame and the rect of its monitor from `MonitorFromWindow`, and the end of full screen puts back the style and the rect from before. `-topmost` is `SetWindowPos` with `HWND_TOPMOST` or `HWND_NOTOPMOST`. No call shows a hidden window, so the test changes a hidden window and reads the styles and the rect back. The setting for less motion comes from `SPI_GETCLIENTAREAANIMATION`: false when the animation effects are off in the settings of Windows.

## Direct APIs

`ztk::win::*` (ztk#66, `src/winapi.zig`) are the commands of Windows alone. They exist on each platform and give `ZTK WIN UNAVAILABLE` on a backend with no such entry, as `ztk::mac::*` give `ZTK MAC UNAVAILABLE`, and `ztk::has win` tells a script.

- `ztk::win::backdrop window ?auto|none|mica|acrylic|tabbed?` sets `DWMWA_SYSTEMBACKDROP_TYPE` with `DwmSetWindowAttribute`, from Windows 11 22H2, and gives `ZTK WIN BACKDROP` on an older system. With no type it gives the backdrop that it set last. The surface of ztk is opaque, so the backdrop shows in the title bar. The whole window needs a surface with alpha, with the native look (ztk#154).
- `ztk::win::jumplist ?task ...?` sets the tasks of the jump list of the app with `ICustomDestinationList` (`src/platform/winjump.zig`): one `IShellLinkW` for each task, this program with its `args`, with `PKEY_Title` for the title, the description, and the icon. With no task, `DeleteList` removes the list of the app. A commit changes the shell state of the user for the program, so the test builds a list and drops it with `AbortList`.
- `ztk::win::thumbbar window ?button ...?` sets up to 7 buttons on the thumbnail of the taskbar button with `ITaskbarList3`. Each button is a dict of `image` (a photo), `tooltip`, `command`, and `disabled`. The shell reads the count of buttons once, at `ThumbBarAddButtons`, so the backend gives it seven slots with the unused ones hidden, and `ThumbBarUpdateButtons` changes them later. The shell refuses the buttons until it made the taskbar button, so the message "TaskbarButtonCreated" adds them, also after Explorer starts again. A click is `WM_COMMAND` with `THBN_CLICKED` and the index of the button, and runs the `command` of the button, which the wm state of the toplevel keeps.
