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
| 2 | `src/platform/win32.zig` and `src/render/d3d12_api.zig`: the Win32 functions and the COM interfaces that ztk calls | Unit tests that make a window class and a hidden window |
| 3 | The Direct3D 12 renderer, offscreen | Each golden scene drawn by Direct3D 12 equals the CPU image within the tolerance of the Vulkan tests |
| 4 | The Win32 backend: windows, the event loop, the frame clock, the scale, and a swapchain target. The CPU output with `SetDIBitsToDevice` when no Direct3D 12 device exists. | Window tests that run only with `ZTK_TEST_WINDOWS=1` |
| 5 | Keyboard, pointer, wheel, and cursors (`setCursor`) | Unit tests of the key and modifier maps from recorded messages |
| 6 | The clipboard of the system (`clipboardGet`, `clipboardSet`) | `clipboard` tests against the clipboard of the CI machine |
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

Input methods use the Text Services Framework (TSF), by the decision of the user (2026-11-25). At start, the UI thread calls `CoInitializeEx` for a single-threaded apartment, makes the thread manager (`CLSID_TF_ThreadMgr`), and calls `Activate`. Each window has a document manager with one context. The context gets a text store of ztk, a COM object in Zig that implements `ITextStoreACP2` and `ITfContextOwnerCompositionSink`. The store has the text of the current composition only. `OnStartComposition` and `OnUpdateComposition` give `preedit` with the text of the composition range and the caret in it. `OnEndComposition` gives `commit` with the text that the input method left, and the store then empties. `GetTextExt` and `GetScreenExt` give the caret rectangle of `textInput`, in screen pixels, so the candidate window shows at the caret. The DLLs are `ole32` and `msctf`, both parts of Windows.

## The event loop

Win32 gives the messages of a window only to the thread that made it. The UI thread of ztk makes the windows, so the backend is a plain `Platform`:

- The program sets the awareness `PER_MONITOR_AWARE_V2` with `SetProcessDpiAwarenessContext` before the first window.
- The window procedure turns each message into an `Event` and appends it to the queue of the backend. `wait(timeout)` calls `MsgWaitForMultipleObjectsEx` with the timeout and the frame handle of each window. `poll` empties the message queue with `PeekMessageW`, `TranslateMessage`, and `DispatchMessageW`, and moves the queue to `out`.
- `WM_KEYDOWN` gives the keysym from a map of virtual keys, and the `WM_CHAR` that follows gives the text of that key. The two join in one `key` event. A surrogate pair joins before the event.
- `WM_MOUSEWHEEL` and `WM_MOUSEHWHEEL` give `scroll` events, with 120 units for one step of the wheel. A touchpad gives smaller units.
- The pointer messages call `Window.feedPointer` too.
- The scale is `GetDpiForWindow / 96`. `WM_DPICHANGED` gives a `scale` event, and the backend moves the window to the rectangle that the message suggests.
- The frame clock is the waitable object of the swapchain (`GetFrameLatencyWaitableObject`), with a latency of one frame. It gives one `frame` event for each `requestFrame`. With the CPU output, the clock is a waitable timer at the refresh rate of `DwmGetCompositionTimingInfo`.

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

## CI

A `test-windows` job on `windows-latest` runs `zig build`, `zig build test`, and the headless script of the Linux job. From PR 3 on, the Direct3D 12 tests run on the WARP adapter of the runner, or print `SKIP:` with the reason.

## Rules for the tests

Rule 12 of `AGENTS.md` forbids windows on the live desktop session of the development machine. The Direct3D 12 tests draw offscreen. The tests of PR 2 make a window with no `WS_VISIBLE` and never show it. The window tests of PR 4 run only with `ZTK_TEST_WINDOWS=1`, which CI sets.

## Limits

- `DefWindowProc` runs its own message loop while a person moves or sizes a window. The UI thread does not return to the loop of the App in that time, so the window shows its last frame until the move ends. A timer during `WM_ENTERSIZEMOVE` can run the loop of the App, in a later PR.
- The pointer positions reach the render thread from the UI thread only, so a drag that the render thread moves stops while the UI thread is busy.
- The fonts of the system (DirectWrite) and the accessibility tree (UI Automation) are not part of this plan.

## Decisions

- The input method is TSF from its first PR. The user decided this on 2026-11-25.

## Decisions for the user

1. The default backend of `ztk` on Windows. The recommendation is Win32, and the headless backend with `--headless` and in CI, as on Linux and macOS.
