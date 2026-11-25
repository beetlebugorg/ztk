# The macOS backend

This page is the plan for the native macOS backend: AppKit for the windows and the input, and Metal for the drawing. Section 4.12 of [the plan](plan.md) names this pair, and decision D3 rules out a translation layer such as MoltenVK. The work is in the platform layer (`src/platform/`), the render layer (`src/render/`), and `src/sys/`. It does not change the widgets.

## Where ztk is on macOS

Measured on 2026-11-25 on an Apple M1 (MacBookPro17,1) with macOS 27.0 and Zig 0.16.0:

- `zig build` builds `zig-out/bin/ztk` with the headless backend only. The cross job of CI builds the same for `x86_64-macos` and `aarch64-macos`.
- `zig build test` did not compile: `src/ztk.zig` imports `tests/vulkan.zig` in each build, and that file needs `vulkan/vulkan.h`.
- With that import behind the `vulkan` build option, test 315 (`fluid: a keyframe animation moves while the script is busy`) did not end. `RenderThread.retarget` waited for `held_drawing` to be false. The render thread drew the held frame again in a loop for the infinite animation and took the mutex back before the waiting thread ran. A stack sample (`sample <pid> 2`) showed the UI thread in `retarget` and the render thread in `sleepUs` between two draws.
- With both changes, `zig build test` passes 447 of 447 tests in 2 minutes (Debug, `--summary all`).

## The PRs

Each PR is small, has its own tests, and passes CI before the next one starts.

| # | PR | Tests |
|---|---|---|
| 1 | This plan | |
| 2 | The tests on macOS: the two changes above, and a CI job on `macos-latest` | `zig build test` on macOS in CI |
| 3 | `src/sys/objc.zig`: calls to the Objective-C runtime from Zig | Unit tests that make an `NSString` and a class at run time |
| 4 | The Metal renderer, offscreen | Each golden scene drawn by Metal into a texture equals the CPU image within the tolerance of the Vulkan tests |
| 5 | The AppKit backend: windows, the event loop, the display link, and a `CAMetalLayer` target | A window test that runs only with `ZTK_TEST_WINDOWS=1` |
| 6 | Keyboard, pointer, scroll, and cursors | Unit tests of the key and modifier maps from recorded `NSEvent` values |
| 7 | The clipboard of the system | `clipboard` tests against `NSPasteboard` with a private pasteboard name |
| 8 | Input methods (`NSTextInputClient`) | Unit tests of the marked text and the commit events |
| 9 | HiDPI changes, the dark mode, and the accent color of the system | Unit tests of the scale and appearance events |
| 10 | Native menus: the menu bar of the app with the standard app menu, and `NSMenu` popups for `tk_popup` and `menubutton`, through the menu interface of task 12 | A window test of a menu bar and a popup that runs only with `ZTK_TEST_WINDOWS=1`, and unit tests of the map from Tk menu entries to `NSMenuItem` values |

## The platform interface

The backend fills the `Platform.VTable` of `src/platform/platform.zig`. The table has what a window and a frame need. The macOS and Windows backends need four more things. Each one is an optional entry, so the headless, direct, and Wayland backends do not change.

| Entry | Purpose | macOS | Windows |
|---|---|---|---|
| `setCursor(window, shape)` | The pointer shape over a widget | `NSCursor` | `SetCursor` |
| `clipboardGet(type)`, `clipboardSet(type, data)` | The clipboard of the system. `src/clipboard.zig` keeps a local store today. | `NSPasteboard` | `OpenClipboard` |
| `textInput(window, on, rect)` | Turns on input methods for a focused text widget and gives the caret rectangle for the candidate window | `NSTextInputClient` | TSF |
| `appearance()` | The dark mode and the accent color | `NSApp.effectiveAppearance`, `NSColor.controlAccentColor` | The `UISettings` colors in the registry |

Two event kinds go into `src/event.zig`: `preedit` (the marked text and the caret in it) and `commit` (the text to insert). The Wayland backend gets the same events from `text-input-v3` in Stage 8. The PR that adds them is PR 8, and it changes no widget beyond the entry and the text widget that read them.

## The event loop

AppKit runs its windows and events on the main thread of the process. The UI thread of ztk is that thread in the `ztk` program, so the backend is a plain `Platform`:

- `wait(timeout)` calls `nextEventMatchingMask:untilDate:inMode:dequeue:` with the timeout and calls `sendEvent:` on the event, so the menus and the window frame of AppKit work. `poll` does the same for the events that wait, with no time limit, and moves the ztk events to the core. A callback that adds an event while `wait` blocks posts an empty application event, and the wait ends.
- A window has a content view of a class that the backend makes at run time with `objc_allocateClassPair`. Its methods turn the `NSEvent` values into ztk events.
- The frame clock is the display link of the view (`NSView.displayLinkWithTarget:selector:`, macOS 14 and later), or a timer at 60 Hz on an older system. It gives one `frame` event for each `requestFrame`, and the link pauses between them.
- Each window has a Metal renderer of its own, so the render threads of two windows share no buffer and no atlas.
- An embedder that runs its own `NSApplication` loop calls `poll` from a run loop observer. That mode is a later PR.

The backend calls the Objective-C runtime with `objc_msgSend` through typed function pointers, from Zig, so it needs no Objective-C compiler and no framework headers. It links AppKit, Metal, QuartzCore, and CoreGraphics (for the sRGB colorspace of the layer), and no other library. The link needs the macOS SDK of the Command Line Tools, so the cross job on Linux keeps `-Dbackends=headless` for the macOS targets.

## The Metal renderer

`src/render/metal.zig` fills the `Renderer` interface of `src/render/renderer.zig`, with the design of the Vulkan renderer:

- One `Quad` is one instance. The vertex function makes the four corners of a triangle strip. One draw call draws each atlas page.
- The instance buffer is a shared `MTLBuffer`. It grows by a factor of two. The render thread waits for the command buffer of a frame before it writes the buffer again, as the Vulkan renderer waits for its queue.
- The atlas page is an `R8Unorm` texture. It uploads again when the generation of the atlas changes.
- The shaders are Metal Shading Language source, a port of `src/render/shaders/quad.vert` and `quad.frag`, with the same formulas as `renderer.zig`. The renderer compiles the source at start with `newLibraryWithSource:options:error:`, so the build needs no `xcrun metal`.
- Colors blend in sRGB space, as the CPU renderer and CSS do. The target format is `BGRA8Unorm`, and the colorspace of the layer is sRGB.
- The window target is a `CAMetalLayer` on the content view. The render thread gets a drawable with `nextDrawable`, draws, and presents it. Metal and `CAMetalLayer` work from a thread other than the main thread.
- The offscreen target is an `MTLTexture`. The tests read it back and compare it with the CPU image of the same scene.
- HiDPI: the layer has `contentsScale` equal to `backingScaleFactor`, and `drawableSize` in device pixels. The scene is in logical pixels, and the renderer scales it, as the Vulkan renderer does.
- `MTLCreateSystemDefaultDevice` returning nil gives `error.NoMetal`. In PR 5 the window then fails to open. The CPU renderer that writes its image to the layer comes in a later PR.

## Input

- Keys: `keyDown:`, `keyUp:`, and `flagsChanged:` give key events. The key code maps to a keysym with the US layout and `UCKeyTranslate` for the current layout. The modifier map is a decision for the user (below).
- Pointer: `mouseDown:`, `mouseDragged:`, `mouseUp:`, the right and other buttons, and `mouseMoved:` with a tracking area. `mouseExited:` gives `leave`. Each position goes to `Window.feedPointer` as well, so a drag follows the pointer from the render thread. The right button is Button-3 and the middle button Button-2, as on the other backends and in Tk 9. Tk 8.6 on macOS numbers them the other way.
- The names `Command` (Mod1) and `Option` (Mod2) work in `bind` on each system. A key with Command or Control gives no text, so `<Command-c>` runs its binding and types no character. A key with Option gives its character, so Option-s types ß.
- Scroll: `scrollWheel:` with `hasPreciseScrollingDeltas` gives fractional deltas in logical pixels. The momentum phase of the event goes to the scroll code of the core. Line deltas from a mouse wheel scale by the line height of Tk.
- Input methods: the view adopts `NSTextInputClient`. `setMarkedText:selectedRange:replacementRange:` gives `preedit`, `insertText:replacementRange:` gives `commit`, and `firstRectForCharacterRange:actualRange:` returns the rectangle from `textInput`.

## CI

The `test` job gets a matrix entry for `macos-latest`. The macOS runner has no Linux build tools to install. The step runs `zig build`, `zig build test`, and the headless script that the Linux job runs. From PR 4 on, the Metal tests run when `MTLCreateSystemDefaultDevice` gives a device, and they print `SKIP: no Metal device` when it gives none. It is not yet checked if the virtual machines of `macos-latest` have a Metal device. PR 4 says which result CI gives.

## Rules for the tests

Rule 12 of `AGENTS.md` forbids windows on the live desktop session of the development machine. The Metal tests draw offscreen. The window tests of PR 5 run only with `ZTK_TEST_WINDOWS=1`, which CI sets.

## Decisions

The user decided these on 2026-11-25 (comments on the PR of this plan):

1. The modifier map is the map of Tk on macOS. The `bind` manual page of Tk 8.6 lists `Command` as a name of `Mod1` and `Option` as a name of `Mod2`. A script with `<Command-c>` works on Tk and on ztk.
2. The default backend of `ztk` on macOS is AppKit with the Metal renderer. The CPU renderer is the fallback when Metal gives no device. `--headless` selects the headless backend, as on Linux.
3. Menus are native on each platform, and they do not wait for Stage 7 (changed on 2026-11-25, a later comment on the PR of this plan). macOS uses `NSMenu` for the menu bar of the app and for popup menus. Task 12 adds an optional menu interface to `src/platform/platform.zig` first: the menu bar of a window, a popup at a point, a change to one entry, and an event for an entry that the user picks. PR 10 fills it for AppKit. The dialogs of decision D9 still wait for Stage 7.
