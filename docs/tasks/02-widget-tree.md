# Task 02: App, widget tree, `frame`, `destroy`, `winfo`

## Goal

A script can make a tree of `frame` widgets, ask about the tree with `winfo`, and delete widgets with `destroy`. No widget has a size or a picture yet.

## Files

- `src/app.zig`: `App`
- `src/widget.zig`: `Widget`, `Class`, the path rules
- `src/cmds.zig`: `destroy`, `winfo`, and the registration of all commands
- `src/widgets/frame.zig`, `src/widgets/toplevel.zig`
- `src/testing.zig`: `Harness`

## Interfaces

```zig
// src/app.zig
pub const Options = struct {
    /// The class of ".". Tk uses the program name with a capital letter.
    root_class: []const u8 = "Ztk",
    /// The result of `winfo name .`.
    app_name: []const u8 = "ztk",
};
pub const App = struct {
    gpa: std.mem.Allocator,
    it: *ztcl.Interp,
    root: ?*Widget = null,                               // "."
    widgets: std.StringHashMapUnmanaged(*Widget) = .empty, // by path
    classes: std.StringHashMapUnmanaged(*const Class) = .empty, // by command name
    /// Widgets that were deleted during a callback. `sweep` frees them.
    dead: std.ArrayListUnmanaged(*Widget) = .empty,

    pub fn init(gpa: std.mem.Allocator, it: *ztcl.Interp, opts: Options) !*App;
    pub fn deinit(app: *App) void;
    /// The App of an interpreter. It reads the `ctx` of the command
    /// `ztk::priv::app`.
    pub fn of(it: *ztcl.Interp) *App;
    pub fn find(app: *App, path: []const u8) ?*Widget;
    pub fn sweep(app: *App) void;
};
```

```zig
// src/widget.zig
pub const State = packed struct(u16) {
    hover: bool = false, pressed: bool = false, focus: bool = false,
    disabled: bool = false, selected: bool = false, readonly: bool = false,
    invalid: bool = false, alternate: bool = false, background: bool = false,
    _pad: u7 = 0,
};
pub const Dirty = packed struct(u8) {
    style: bool = true, measure: bool = true, layout: bool = true,
    paint: bool = true, _pad: u4 = 0,
};
pub const Widget = struct {
    app: *App,
    path: []const u8,          // owned, for example ".f.ok"
    class: *const Class,
    tk_class: []const u8,      // for example "Frame"
    parent: ?*Widget,
    children: std.ArrayListUnmanaged(*Widget) = .empty, // lowest first
    geom: geom.Rect = .{},     // position in the parent, and size
    req: geom.Size = .{},      // requested size
    mapped: bool = false,
    state: State = .{},
    dirty: Dirty = .{},
    destroyed: bool = false,
    data: ?*anyopaque = null,  // the data of the class

    pub fn name(w: *const Widget) []const u8;     // the last part of the path
    pub fn toplevel(w: *Widget) *Widget;
    pub fn isToplevel(w: *const Widget) bool;
    /// Sets flags on this widget and the flags that follow from them.
    pub fn invalidate(w: *Widget, d: Dirty) void;
};
pub const Class = struct {
    command: []const u8,   // "frame"
    tk_class: []const u8,  // "Frame"
    is_toplevel: bool = false,
    focusable: bool = false,
    init: ?*const fn (w: *Widget) anyerror!void = null,
    deinit: ?*const fn (w: *Widget) void = null,
    /// A widget subcommand other than `configure` and `cget`. It returns
    /// null when the class does not have the subcommand.
    subcommand: ?*const fn (w: *Widget, it: *ztcl.Interp, argv: []const ztcl.Value) ztcl.Error!?ztcl.Value = null,
};
/// Makes a widget and its command. `path` must have an existing parent.
pub fn create(app: *App, class: *const Class, path: []const u8) ztcl.Error!*Widget;
/// Deletes a widget, its children first, and its command.
pub fn destroy(w: *Widget) void;
```

```zig
// src/testing.zig
pub const Harness = struct {
    it: ztcl.Interp,
    app: *App,
    pub fn init(h: *Harness) !void;   // uses std.testing.allocator
    pub fn deinit(h: *Harness) void;
    /// Evaluates a script and returns the string of the result.
    pub fn eval(h: *Harness, script: []const u8) ![]const u8;
    /// Expects error.TclError and returns the message.
    pub fn evalError(h: *Harness, script: []const u8) ![]const u8;
};
```

## Steps

1. `App.init` makes the namespaces `::ztk` and `::ztk::priv` with `it.eval("namespace eval ::ztk::priv {}")`. It registers the command `ztk::priv::app` and sets its `ctx` to the `App`. It registers `frame`, `destroy`, and `winfo`. It makes the root widget `.` with the toplevel class and the command `.`.
2. A widget constructor (`frame .f ?options?`) checks the path, makes the widget, and returns the path. Task 03 adds the options. In this task, an argument after the path gives the error of an unknown option.
3. The path rules. Get each message from `wish`:
   - The parent must exist. `frame .x.y` with no `.x` gives `bad window path name ".x"`: the message names the parent.
   - The name must not exist: `window name "f" already exists in parent`.
   - The name must not start with a capital letter: `window name starts with an upper-case letter: "Bad"`.
   - `.` exists from the start and cannot be made again.
4. The widget command has the name of the path. `.f configure` and `.f cget` come in task 03. Until then, each subcommand gives the error of `wish` for a frame: `bad option "bogus": must be cget or configure`.
5. `destroy ?path ...?` deletes each widget and its children, children first. A path that does not exist is not an error. `destroy .` deletes all widgets. After it, `app.root` is null.
6. A widget that is deleted while a callback of it runs stays in memory until `App.sweep`. Set `destroyed`, remove it from the tree and from `widgets`, and add it to `dead`. `sweep` runs when no callback is active. In this task, each command calls `sweep` at its end when the nesting of ztk callbacks is 0.
7. `winfo`: `children path` (stacking order), `exists path` (0 or 1, no error for a bad path), `parent path` (empty for `.`), `class path`, `name path` (the name of `.` is the application name: `App.Options.app_name`, with the default `ztk`; `wish` uses the name of the script file), `toplevel path`. Each other subcommand gives the `bad option` error with the complete list of `wish`. A path that does not exist gives `bad window path name "x"`.
8. `frame` accepts `-class name` at creation in task 03. In this task the class is always `Frame`.

## Tests

```sh
zig build test -Dtest-filter=widget
zig build test -Dtest-filter=winfo
```

Unit tests, each with a `Harness`:

- `frame .a; frame .a.b; winfo children .` gives `.a`. `winfo children .a` gives `.a.b`.
- `winfo parent .a.b` gives `.a`. `winfo parent .` gives an empty string.
- `winfo class .a` gives `Frame`. `winfo name .a.b` gives `b`. `winfo toplevel .a.b` gives `.`.
- `frame .x.y` fails with `bad window path name ".x"`. `frame .Bad` fails with the upper-case message.
- A second `frame .a` fails with the message of `wish`.
- `destroy .a` removes `.a` and `.a.b`: `winfo exists .a.b` gives `0`, and the command `.a.b` does not exist.
- `destroy .nosuch` gives no error.
- A test with `std.testing.allocator` makes 1 000 frames in a tree, deletes `.`, and has no leak.
- `frame .a` gives `.a` as its result.

Check each expected text with:

```sh
printf 'catch {frame .x.y} m; puts $m; exit\n' > /tmp/t.tcl && xvfb-run -a wish /tmp/t.tcl
```

## Acceptance

- All tests pass with no leak report.
- Each error message in the tests is the text of `wish` 8.6.16.
- No file other than `src/cmds.zig` calls `it.register`, except for widget commands in `src/widget.zig`.

## Out of scope

- Options, sizes, layout, and paint.
- `toplevel` as a script command. Only `.` exists in Stage 1.
- `rename` of a widget command.
- The other `winfo` subcommands. Task 11 adds the geometry ones.
