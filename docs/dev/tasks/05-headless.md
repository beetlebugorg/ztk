# Task 05: The backend interface and the headless backend

## Goal

One interface describes a platform. The headless backend implements it in memory, with a clock and input that a test controls. All tests of the later tasks use it.

## Files

- `src/platform/platform.zig`: `Platform`, `Window`
- `src/base/event.zig`: `Event`, `Mods`
- `src/base/keysym.zig`: the names and numbers of key symbols
- `src/platform/headless.zig`
- `src/app.zig`, `src/testing.zig`

## Interfaces

```zig
// src/base/event.zig
pub const Mods = packed struct(u16) {
    shift: bool = false, lock: bool = false, control: bool = false,
    mod1: bool = false,   // Alt
    mod2: bool = false, mod3: bool = false,
    mod4: bool = false,   // the logo key
    mod5: bool = false,
    button1: bool = false, button2: bool = false, button3: bool = false,
    button4: bool = false, button5: bool = false, _pad: u3 = 0,
};
pub const Event = union(enum) {
    /// x and y are logical pixels in the window.
    motion: struct { window: *Window, x: f32, y: f32, mods: Mods, time_ms: u32 },
    button: struct { window: *Window, button: u8, pressed: bool, x: f32, y: f32, mods: Mods, time_ms: u32 },
    leave: struct { window: *Window },
    scroll: struct { window: *Window, dx: f32, dy: f32, x: f32, y: f32, mods: Mods, time_ms: u32 },
    key: struct {
        window: *Window, keysym: u32, keycode: u32, pressed: bool, repeat: bool,
        text: [8]u8 = @splat(0), text_len: u8 = 0, // the UTF-8 that the key gives
        mods: Mods, time_ms: u32,
    },
    focus: struct { window: *Window, focused: bool },
    resize: struct { window: *Window, size: geom.Size },
    scale: struct { window: *Window, scale: f32 },
    close: struct { window: *Window },
    frame: struct { window: *Window, time_us: i64 },
};
```

```zig
// src/base/keysym.zig
/// The number of a key symbol name ("Return", "a", "space"), or null.
pub fn fromName(name: []const u8) ?u32;
/// The name of a number, or null.
pub fn toName(sym: u32) ?[]const u8;
```

```zig
// src/platform/platform.zig
pub const WindowOptions = struct { title: []const u8 = "", size: geom.Size = .{ .w = 200, .h = 200 } };
pub const Window = struct {
    size: geom.Size,          // logical pixels
    scale: f32 = 1,
    user: ?*anyopaque = null, // the toplevel widget
    impl: ?*anyopaque = null, // data of the backend
};
pub const Platform = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        createWindow: *const fn (ptr: *anyopaque, opts: WindowOptions) anyerror!*Window,
        destroyWindow: *const fn (ptr: *anyopaque, w: *Window) void,
        setTitle: *const fn (ptr: *anyopaque, w: *Window, title: []const u8) void,
        /// Asks for a size. The backend answers with a `resize` event.
        requestSize: *const fn (ptr: *anyopaque, w: *Window, size: geom.Size) void,
        setMinSize: *const fn (ptr: *anyopaque, w: *Window, size: geom.Size) void,
        /// Asks for one `frame` event at the next display refresh.
        requestFrame: *const fn (ptr: *anyopaque, w: *Window) void,
        /// Blocks until an event exists or the time passed. Null: no limit.
        wait: *const fn (ptr: *anyopaque, timeout_us: ?i64) void,
        /// Moves the pending events to `out`.
        poll: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Event)) anyerror!void,
        nowUs: *const fn (ptr: *anyopaque) i64,
        /// Draws a scene to the window. Task 06 defines Scene.
        draw: *const fn (ptr: *anyopaque, w: *Window, s: *const anyopaque) anyerror!void,
    };
    pub fn clock(p: Platform) loop.Clock;
};
```

```zig
// src/platform/headless.zig
pub const Headless = struct {
    pub fn init(gpa: std.mem.Allocator) !*Headless;
    pub fn platform(h: *Headless) Platform;
    // Test controls. Each one adds events to the queue.
    pub fn advance(h: *Headless, ms: i64) void;          // moves the clock
    pub fn pointerMove(h: *Headless, w: *Window, x: f32, y: f32) void;
    pub fn pointerButton(h: *Headless, w: *Window, button: u8, pressed: bool) void;
    pub fn click(h: *Headless, w: *Window, x: f32, y: f32) void; // move, press 1, release 1
    pub fn pointerLeave(h: *Headless, w: *Window) void;
    pub fn key(h: *Headless, w: *Window, name: []const u8, pressed: bool) !void;
    pub fn press(h: *Headless, w: *Window, name: []const u8) !void; // down and up
    pub fn typeText(h: *Headless, w: *Window, utf8: []const u8) !void;
    pub fn setMods(h: *Headless, mods: Mods) void;
    pub fn resize(h: *Headless, w: *Window, size: geom.Size) void;
    pub fn setScale(h: *Headless, w: *Window, scale: f32) void;
    pub fn setFocused(h: *Headless, w: *Window, focused: bool) void;
    pub fn close(h: *Headless, w: *Window) void;
    /// Counts of calls, for the tests.
    frames_requested: u32 = 0,
    frames_drawn: u32 = 0,
};
```

## Steps

1. `App.Options` gets `platform: Platform`. `App.init` makes the window of `.` with `createWindow`. `Window.user` is the root widget.
2. `App.doOneEvent` starts with `poll`. It handles each event in order, then the timers, then the idle entries. With `wait`, it calls `Platform.wait` with `Loop.nextTimeoutUs`.
3. In this task the App handles two events. `resize` sets the size of the toplevel and its layout flag. `close` deletes the toplevel. Tasks 11, 12, and 13 add the rest.
4. The headless backend:
   - The clock starts at 0. `wait(t)` moves the clock by `t` when no event is in the queue. `wait(null)` with an empty queue returns at once.
   - `requestSize` adds a `resize` event with that size.
   - `requestFrame` sets a flag and counts. The next `poll` adds one `frame` event for that window.
   - The pointer state (position and buttons) is in the backend. `pointerButton` uses the last position. The `mods` of each event have the button bits of the buttons that were down before the event, as in X11.
   - `typeText` adds a press and a release for each character, with the key symbol of the character and its UTF-8 in `text`. Add `shift` for a capital letter.
   - `draw` counts the call. Task 06 gives it the CPU renderer.
5. `src/base/keysym.zig` has a table for Stage 1: the printable ASCII characters (the names are in `keysyms.n`: `space`, `exclam`, `a`, `A`, `0`, and so on), `Return`, `Tab`, `ISO_Left_Tab`, `Escape`, `BackSpace`, `Delete`, `Left`, `Right`, `Up`, `Down`, `Home`, `End`, `Prior`, `Next`, `Shift_L`, `Shift_R`, `Control_L`, `Control_R`, `Alt_L`, `Alt_R`, `Super_L`, and `F1` to `F12`. The numbers are the X11 key symbol values in `keysyms.n`. A Latin-1 character has its code point as the number. A test checks `a`, `Return`, and `space` against `keysyms.n`.
6. `Harness` makes a `Headless` and gives it to the App. It gets these helpers: `h.head` (the backend), `h.win` (the window of `.`), and `h.update()` (the `update` command).

## Tests

```sh
zig build test -Dtest-filter=headless
zig build test -Dtest-filter=keysym
```

- A `resize` to 300 by 200 changes the size of `.` after `h.update()`.
- `close` deletes `.`, and `App.run` returns.
- `requestFrame` two times before a `poll` gives one `frame` event.
- `advance(100)` makes a 100 ms timer due.
- `typeText("aB")` gives four key events. The third has the key symbol `B`, the text `B`, and `shift`.
- A button event after `pointerMove(10, 20)` has `x = 10` and `y = 20`.
- A motion event while button 1 is down has `button1` in `mods`.
- `keysym.fromName("Return")` is `0xff0d`. `keysym.toName(0x61)` is `a`. `keysym.fromName("nosuch")` is null.

## Acceptance

- All tests pass.
- `src/app.zig` calls the backend only through `Platform`. `grep -n headless src/app.zig` finds no line.
- No test of this task or of a later task opens a real window, unless the task says so.

## Out of scope

- Pointer and key dispatch to widgets. Tasks 12 and 13.
- Drawing. Task 06.
- The clipboard, the cursor shape, and more than one window.
