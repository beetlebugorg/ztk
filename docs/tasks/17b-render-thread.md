# Task 17b: The render thread

## Goal

Drawing is not on the thread that runs the script. The UI thread runs the interpreter, the style, the layout, and the paint, and makes a scene. The render thread draws the newest scene and shows it. A slow script does not stop a frame that is ready, and a slow draw or a wait for the display does not stop the script.

The plan has the reason in decision D23.

## Files

- `src/render/thread.zig`: the render thread and the hand-over
- `src/scene.zig`: `Frame`, the atlas changes of a scene
- `src/text/atlas.zig`: the list of changed regions
- `src/app.zig`, `src/platform/platform.zig`, `src/platform/headless.zig`, `src/platform/wayland.zig`

## Interfaces

```zig
// src/scene.zig
/// A region of the atlas page with its new bytes.
pub const AtlasPatch = struct { x: u32, y: u32, w: u32, h: u32, bytes: []const u8 };
/// All that the render thread needs for one frame. It has no pointer
/// into the widget tree or the interpreter.
pub const Frame = struct {
    scene: Scene,
    patches: std.ArrayListUnmanaged(AtlasPatch) = .empty,
    serial: u64 = 0,
    pub fn reset(f: *Frame) void;
};

// src/render/thread.zig
pub const Mode = enum { threaded, inline_draw };
pub const Target = struct {
    ctx: *anyopaque,
    /// Draws and shows one frame. It runs on the render thread.
    draw: *const fn (ctx: *anyopaque, frame: *const Frame) anyerror!void,
};
pub const RenderThread = struct {
    pub fn init(gpa: std.mem.Allocator, mode: Mode, target: Target) !*RenderThread;
    /// Stops the thread after its current frame and joins it.
    pub fn deinit(r: *RenderThread) void;
    /// The frame that the UI thread fills next. It is never the frame
    /// that the render thread reads.
    pub fn back(r: *RenderThread) *Frame;
    /// Hands the back frame to the render thread and returns at once.
    /// A frame that the render thread did not start is replaced.
    pub fn submit(r: *RenderThread) void;
    /// Blocks until the render thread showed all submitted frames.
    pub fn flush(r: *RenderThread) void;
    /// Counts, for the tests and the statistics.
    drawn: std.atomic.Value(u64),
    replaced: std.atomic.Value(u64),
};
```

## Steps

1. Three `Frame` values exist: one that the UI thread fills, one that waits, and one that the render thread reads. `submit` swaps the back frame with the waiting frame under a mutex and wakes the render thread. The render thread swaps the waiting frame with its own frame before a draw. No frame is copied and no thread waits for the other in `submit`.
2. The render thread owns the renderer, its GPU objects, and the present step. For the Vulkan renderer, all Vulkan calls after `init` are on the render thread. For the CPU renderer, the image, `changedRows`, and the write to the display are on the render thread.
3. The atlas. The UI thread makes glyph images during the paint and keeps the atlas page. For each change, it adds an `AtlasPatch` with a copy of the bytes to the frame. The render thread has its own copy of the page (the CPU renderer) or the texture (Vulkan) and applies the patches before the draw. When a waiting frame is replaced, its patches move to the new frame, in order. No patch is lost.
4. `Platform.draw` is replaced by `Platform.target(window) Target`. The App fills `back()` in the paint stage and calls `submit`. The backend gives the frame event on the UI thread, as before.
5. A resize. The UI thread sends the new size in the next frame (`scene.width`, `scene.height`). The render thread makes its target again when the size of a frame differs from its target.
6. `inline_draw` runs `draw` inside `submit` on the calling thread. The golden tests, the oracle, and a platform with no threads (the web build of Stage 3) use it. Both modes give the same pixels.
7. `update` and `update idletasks` call `flush` after `submit`, so that a script and a test see the frame on the display when `update` returns.
8. Shutdown: `deinit` runs before the backend deletes the window and before `Vulkan.deinit`.
9. The render thread touches no widget, no style, no interpreter value, and no allocator of the UI thread, except the frame it owns. Each `Frame` has its own arena.
10. The frame statistics of task 18 measure the stages of the UI thread and the draw time of the render thread separately.
11. Threads need no libc in Zig on Linux. The static build of task 20 keeps the render thread.

## Tests

```sh
zig build test -Dtest-filter=renderthread
```

- 1 000 submits with a target that sleeps 1 ms: `submit` never blocks longer than 0.2 ms, `drawn + replaced` is 1 000 after `flush`, and the last frame drawn has the serial 1 000.
- A target that blocks on a test lock: the UI thread runs 100 passes with a timer script while the draw is blocked. Then the lock opens and the newest frame draws.
- A UI thread that is busy for 200 ms after a submit: the frame is drawn in that time (the test reads `drawn` from a third thread).
- Atlas patches of three frames, where two frames are replaced: the copy of the render thread is equal to the page of the UI thread.
- Each golden scene of tasks 06, 07, and 11 gives the same bytes in `threaded` mode and in `inline_draw` mode.
- A resize to three sizes in three frames with no flush between them ends with the last size and no crash.
- `deinit` during a draw waits for the draw and has no leak.
- Run the tests of this task 200 times in a loop. No run fails. Zig has no race detector, so the reviewer also reads each shared field.

## Acceptance

- All tests pass in the loop of 200 runs.
- `grep -n -E 'Widget|Interp|App\b' src/render/thread.zig src/render/cpu.zig src/render/vulkan.zig` finds no use of these types.
- The shared state is one mutex, one condition, the three frame pointers, and atomic counters. The task has no other lock.
- With the Vulkan renderer on Wayland, a script with `after 0` in a loop that uses one full core still shows 60 frames in each second of a hover transition. Record the frame statistics of one manual run with the run of task 19.

## Out of scope

- Animations that the render thread computes while the UI thread is busy. Stage 2.
- More than one render thread, and one thread for each window.
- A thread for the layout or the style.
- Threads in the web build.
