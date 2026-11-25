# Task 17: The Wayland backend and the `ztk` program

## Goal

`ztk script.tcl` opens a real window on a Wayland compositor, draws it with the Vulkan renderer, and sends the keyboard and the pointer to the widgets.

## Files

- `src/platform/wayland.zig`
- `src/render/vulkan.zig`: the surface and the swapchain
- `src/main.zig`: the flags of the `ztk` program
- `build.zig`: `wayland-scanner`, the system libraries
- `tests/wayland-smoke.sh`
- `docs/references/dependencies.md`

## Interfaces

```zig
// src/platform/wayland.zig
pub const Wayland = struct {
    /// Connects to the compositor of WAYLAND_DISPLAY.
    pub fn init(gpa: std.mem.Allocator, vk: *Vulkan) !*Wayland;
    pub fn platform(w: *Wayland) Platform;
    /// The instance extensions that `Vulkan.init` needs for this backend.
    pub const instance_extensions: []const [*:0]const u8;
};

// added to src/render/vulkan.zig
/// A target with a swapchain on a Wayland surface.
pub fn createWaylandTarget(v: *Vulkan, display: *anyopaque, surface: *anyopaque, width: u32, height: u32) !*Target;
pub fn resizeTarget(v: *Vulkan, t: *Target, width: u32, height: u32) !void;
/// Presents the last draw of a swapchain target.
pub fn present(v: *Vulkan, t: *Target) !void;
```

The `ztk` program:

```
ztk [flags] script.tcl [arguments]
  --headless               use the headless backend and the CPU renderer
  --cpu                    use the CPU renderer on Wayland (a shared-memory buffer)
  --exit-after-frames N    exit with status 0 after N frames
  --screenshot FILE.png    with --headless: write the last frame at the exit
  --scale N                with --headless: the scale of the window
  --dark                   the dark color scheme
  --version
```

## Steps

1. `build.zig` links `wayland-client`, `xkbcommon`, and libc, only for this backend. These are the only libraries that Stage 1 links. Vulkan needs the Wayland client library for its surface, and the compositor sends its key map in the XKB format. It runs `wayland-scanner` (`client-header` and `private-code`) for these files of `/usr/share/wayland-protocols`, and compiles the C output with `addCSourceFile`:
   - `stable/xdg-shell/xdg-shell.xml` (required)
   - `unstable/xdg-decoration/xdg-decoration-unstable-v1.xml` (used when the compositor has it)
   - `stable/viewporter/viewporter.xml` and `staging/fractional-scale/fractional-scale-v1.xml` (used when the compositor has both)
   - `staging/cursor-shape/cursor-shape-v1.xml` (used when the compositor has it)
   Find the folder with `pkg-config --variable=pkgdatadir wayland-protocols`.
2. The connection: bind `wl_compositor`, `xdg_wm_base`, and `wl_seat`, and the optional globals. Answer the `ping` of `xdg_wm_base`.
3. The window: a `wl_surface` with an `xdg_surface` and an `xdg_toplevel`. Set the title and the app id (`ztk`). Ask for server-side decorations when `xdg-decoration` exists. With no decoration protocol, the window has no title bar in Stage 1. Record that in `docs/dev/stage1-limits.md`.
4. Size: the first `configure` of the toplevel with a size of 0 means "the client selects". Use the size that the App asked for. A `configure` with a size gives a `resize` event. Acknowledge each configure before the next commit. `requestSize` changes the size only when the compositor did not fix it.
5. Scale: with `fractional-scale` and `viewporter`, use the preferred scale (a count of 120ths), make the buffer `size * scale` rounded to the nearest integer, and set the viewport destination to the logical size. Without them, use the integer scale of `wl_surface.preferred_buffer_scale`, or of the outputs that the surface is on, and `wl_surface.set_buffer_scale`. A change gives a `scale` event.
6. The Vulkan surface: `VK_KHR_wayland_surface`. The swapchain has the present mode FIFO, so a present waits for the display. Select an 8-bit UNORM format (BGRA or RGBA), and not an sRGB format, because the blend is in sRGB space. When the surface gives only an sRGB format, stop with a clear error and record it.
7. Frames: `requestFrame` asks for a `wl_surface.frame` callback, when none is pending, and commits. The callback gives a `frame` event. `draw` renders the scene and presents. The first frame after the first configure needs no callback.
8. A resize makes a new swapchain with the new size before the next draw. `VK_ERROR_OUT_OF_DATE_KHR` and `VK_SUBOPTIMAL_KHR` do the same.
9. The keyboard: `wl_keyboard` gives a keymap. Load it with `xkb_keymap_new_from_string` and keep an `xkb_state`. A key gives a `key` event with `xkb_state_key_get_one_sym`, the key code plus 8, and the UTF-8 of `xkb_state_key_get_utf8`. Update the state on a `modifiers` event. The modifiers of the event come from the state: Shift, Lock, Control, Mod1, Mod4. Key repeat: the client repeats. Use the rate and the delay of `repeat_info` with `Loop.addNative`, and stop at the release, at a focus loss, and at another key press.
10. The pointer: `enter`, `leave`, `motion`, `button`, and `axis`. The positions are logical pixels. The Linux button codes map to the Tk numbers: `BTN_LEFT` (0x110) is 1, `BTN_MIDDLE` (0x112) is 2, `BTN_RIGHT` (0x111) is 3. An `axis` event gives a `scroll` event. No widget of Stage 1 uses it.
11. The cursor: on each pointer `enter`, set the default shape with `cursor-shape` when it exists. With no such protocol, the cursor is the one the compositor shows. Record that in `docs/dev/stage1-limits.md`.
12. Keyboard focus: `wl_keyboard.enter` and `leave` give `focus` events.
13. Close: `xdg_toplevel.close` gives a `close` event.
14. `wait(timeout)`: use `wl_display_prepare_read`, flush, `poll` on the descriptor of the display with the timeout, then `wl_display_read_events` or `wl_display_cancel_read`. `poll` (of the backend interface) calls `wl_display_dispatch_pending` and moves the events to the list.
15. `--cpu` uses the CPU renderer with a `wl_shm` buffer. It is the fallback when `Vulkan.init` fails: print one line to stderr that says so. It reports only the rows of `changedRows` (task 06) as damage, with `wl_surface.damage_buffer`. A frame with no changed row commits no buffer.
16. `src/main.zig`: without `--headless`, connect to Wayland. When `WAYLAND_DISPLAY` is not set, print `ztk: no Wayland display. Use --headless, or run in a Wayland session.` and exit with status 1. Set `App.Options.style_root` to the folder of the script. Run the script, then `App.run`. Exit with status 0 when `.` is deleted, and with status 1 after a script error before the loop starts.
17. Fonts: Stage 1 uses the fonts of the repository on each backend. The fonts of the system are Stage 2.
18. `tests/wayland-smoke.sh` starts a private compositor and runs the program in it:
    ```sh
    export XDG_RUNTIME_DIR="$(mktemp -d)"
    weston --backend=headless --renderer=gl --socket=ztk-test --width=800 --height=600 &
    WAYLAND_DISPLAY=ztk-test zig-out/bin/ztk --exit-after-frames 5 tests/scripts/smoke.tcl
    ```
    The script stops the compositor by its PID at the end. It exits with status 77 when `weston` is not on the path. First try the Vulkan renderer. When the surface or the swapchain fails in the headless compositor, the script runs the program again with `--cpu` and prints which renderer passed. Record the result in the commit message. If neither works in the headless compositor, write the errors in `docs/dev/tasks/BLOCKED.md` and do the manual check of step 19.
19. One manual check on the live session of the development machine, when `WAYLAND_DISPLAY` is set: `zig-out/bin/ztk --exit-after-frames 180 tests/scripts/smoke.tcl`. The window shows for about three seconds. Run it one time only, and only for this task, because the machine is shared. Record the exit status and the frame count.

## Tests

```sh
zig build
zig build test
tests/wayland-smoke.sh
zig-out/bin/ztk --headless --exit-after-frames 1 --screenshot /tmp/ztk-smoke.png tests/scripts/smoke.tcl
zig-out/bin/ztk --version
```

`tests/scripts/smoke.tcl` makes one label, one button, and one entry in a grid.

- The smoke script exits with status 0 and the program printed `frames: 5`.
- The headless command writes a PNG that is equal to the golden image `smoke.png`.
- `env -u WAYLAND_DISPLAY zig-out/bin/ztk tests/scripts/smoke.tcl` exits with status 1 and prints the message of step 16.
- `zig-out/bin/ztk --headless nosuch.tcl` exits with status 1 and names the file.
- A script with a syntax error exits with status 1 and prints the error.
- `tools/oracle.sh` now uses `zig-out/bin/ztk --headless`. The oracle runner of task 10 is removed. The two oracle commands of task 10 still pass.

## Acceptance

- All commands above pass, or `BLOCKED.md` has the exact reason for the smoke script.
- The manual check of step 19 ran one time, with status 0 and 180 frames in 3.0 to 3.5 seconds on a 60 Hz display.
- No Wayland object and no Vulkan object stays alive at the exit: run the smoke script with `ZTK_VK_VALIDATE=1` when the layer exists.
- `src/app.zig` has no Wayland name and no Vulkan name.

## Out of scope

- X11. Stage 2.
- Client-side decorations, the clipboard, drag and drop, input methods, touch, and tablet input.
- More than one window, popups, and the window position.
- The cursor shapes of `-cursor`.
- Multiple monitors with different scales, beyond the `scale` event.
