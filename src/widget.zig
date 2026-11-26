//! The widget tree. A widget is one node with a path, a class, a parent,
//! and children in stacking order. A class is a table of functions.
//! `create` checks the path, makes the node, and registers its command.
//!
//! The life of a widget has three states, and each state only moves forward:
//!
//! - `alive`: the widget is in the path table and takes part in events.
//! - `destroying`: `destroy` started. The widget gets no event except its
//!   own Destroy event, no subsystem holds it, and it gets no new child.
//! - `dead`: the widget left the tree, the table, and the interpreter.
//!   The memory stays on the dead list of the App.
//!
//! `destroy` ends for each tree. A new child needs an alive parent, so
//! the count of alive children of a destroying widget only goes down. A
//! child that is still destroying in an outer call loses its parent link.
//! The App frees the dead list only when `App.enter` has no open call, so
//! a pointer that Zig code holds across a script stays valid memory.
//!
//! The `ctx` of a widget command is a `Handle`. The interpreter can keep a
//! command after its widget is freed: a `namespace import` adds a second
//! key, and an execution trace runs a script before the command. The
//! handle has a nullable widget and lives until `App.deinit`, so each
//! such call finds null and gives `invalid command name`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const geom = @import("geom.zig");
const app_mod = @import("app.zig");
const options = @import("options.zig");
const style_mod = @import("style.zig");
const layout = @import("layout.zig");
const scene = @import("scene.zig");
const bind = @import("bind.zig");
const focus = @import("focus.zig");
const anim = @import("anim.zig");
const App = app_mod.App;

pub const State = packed struct(u16) {
    hover: bool = false,
    pressed: bool = false,
    focus: bool = false,
    disabled: bool = false,
    selected: bool = false,
    readonly: bool = false,
    invalid: bool = false,
    alternate: bool = false,
    background: bool = false,
    /// A scroll moved the view a moment ago (`:scrolling`).
    scrolling: bool = false,
    /// An entry shows its placeholder text (`:placeholder-shown`).
    placeholder: bool = false,
    _pad: u5 = 0,
};

pub const Dirty = packed struct(u8) {
    style: bool = true,
    measure: bool = true,
    layout: bool = true,
    paint: bool = true,
    _pad: u4 = 0,

    pub const none: Dirty = .{ .style = false, .measure = false, .layout = false, .paint = false };

    pub fn merge(a: Dirty, b: Dirty) Dirty {
        return @bitCast(@as(u8, @bitCast(a)) | @as(u8, @bitCast(b)));
    }

    pub fn any(a: Dirty) bool {
        return @as(u8, @bitCast(a)) != 0;
    }
};

pub const Life = enum { alive, destroying, dead };

/// The `ctx` of a widget command. See the top of this file.
pub const Handle = struct {
    widget: ?*Widget,
    /// The next handle of the App, for `App.deinit`.
    next: ?*Handle,
};

pub const Widget = struct {
    app: *App,
    /// Owned by the App allocator, for example ".f.ok".
    path: []const u8,
    class: *const Class,
    tk_class: []const u8,
    parent: ?*Widget,
    children: std.ArrayListUnmanaged(*Widget) = .empty,
    /// Position in the parent, and size.
    geom: geom.Rect = .{},
    /// Requested size.
    req: geom.Size = .{},
    mapped: bool = false,
    state: State = .{},
    /// The states `user1` to `user6` of a `ttk` widget, `user6` in the low bit.
    ttk_user: u8 = 0,
    dirty: Dirty = .{},
    /// The state of the life of the widget. See the top of this file.
    life: Life = .alive,
    /// The `ctx` of the command of the widget.
    handle: ?*Handle = null,
    /// The next widget on the dead list. The list needs no allocation, so a delete cannot fail.
    next_dead: ?*Widget = null,
    /// The data of the class.
    data: ?*anyopaque = null,
    /// One slot for each option spec of the class.
    opts: []options.Slot = &.{},
    /// True after the first style was computed. A new widget does not animate.
    styled: bool = false,
    /// The computed style. Valid when `dirty.style` is false.
    style: style_mod.Style = .{},
    /// The style classes.
    classes: std.ArrayListUnmanaged([]const u8) = .empty,
    /// The geometry manager of this widget, and its data (for grid: `*grid.Cell`).
    manager: ?*const layout.Manager = null,
    manager_data: ?*anyopaque = null,
    /// The manager that places the content of this widget, and its data.
    container_manager: ?*const layout.Manager = null,
    container_data: ?*anyopaque = null,
    /// The data of `pack` for this widget (`*pack.Entry`), and of `place` (`*place.Entry`).
    pack_data: ?*anyopaque = null,
    place_data: ?*anyopaque = null,
    /// The widgets that `place` puts in this widget, oldest first.
    placed: std.ArrayListUnmanaged(*Widget) = .empty,
    /// The tags of the widget for `bind`, or null for the default tags. Owned.
    bindtags: ?[][]u8 = null,
    /// The geometry and the mapped flag that the last Configure, Map, or Unmap event reported.
    cfg_geom: geom.Rect = .{},
    cfg_mapped: bool = false,

    /// The `-style` of a `ttk` widget, or empty.
    pub fn ttkStyle(w: *const Widget) []const u8 {
        if (!w.class.ttk) return "";
        const s = options.maybe(w, "-style") orelse return "";
        return if (s.set) s.text else "";
    }

    /// The type of the widget for a selector: the last part of its `ttk`
    /// style (`Accent.TButton` gives `TButton`), else its Tk class.
    pub fn styleType(w: *const Widget) []const u8 {
        const st = w.ttkStyle();
        if (st.len == 0) return w.tk_class;
        const i = std.mem.lastIndexOfScalar(u8, st, '.') orelse return st;
        return st[i + 1 ..];
    }

    /// True when the widget has a style class. The parts of a `ttk`
    /// style before its type count as classes, with no case, so
    /// `Switch.TCheckbutton` has the class `switch`.
    pub fn hasClass(w: *const Widget, cls: []const u8) bool {
        for (w.classes.items) |c| if (std.mem.eql(u8, c, cls)) return true;
        const st = w.ttkStyle();
        const end = std.mem.lastIndexOfScalar(u8, st, '.') orelse return false;
        var parts = std.mem.splitScalar(u8, st[0..end], '.');
        while (parts.next()) |p| if (std.ascii.eqlIgnoreCase(p, cls)) return true;
        return false;
    }

    pub fn alive(w: *const Widget) bool {
        return w.life == .alive;
    }

    /// The last part of the path.
    pub fn name(w: *const Widget) []const u8 {
        if (w.parent == null) return "";
        const i = std.mem.lastIndexOfScalar(u8, w.path, '.').?;
        return w.path[i + 1 ..];
    }

    /// The path of the toplevel of the widget.
    pub fn toplevelPath(w: *const Widget) []const u8 {
        var x = w;
        while (!x.isToplevel()) x = x.parent orelse return x.path;
        return x.path;
    }

    /// Sets the tags for `bind`. An empty list gives the default tags back.
    pub fn setBindtags(w: *Widget, parts: []const ztcl.Value, it: *ztcl.Interp) !void {
        const gpa = w.app.gpa;
        w.freeBindtags();
        if (parts.len == 0) return;
        const list = try gpa.alloc([]u8, parts.len);
        var n: usize = 0;
        errdefer {
            for (list[0..n]) |t| gpa.free(t);
            gpa.free(list);
        }
        for (parts) |p| {
            list[n] = try gpa.dupe(u8, try it.str(p));
            n += 1;
        }
        w.bindtags = list;
    }

    fn freeBindtags(w: *Widget) void {
        const gpa = w.app.gpa;
        if (w.bindtags) |list| {
            for (list) |t| gpa.free(t);
            gpa.free(list);
            w.bindtags = null;
        }
    }

    pub fn toplevel(w: *Widget) *Widget {
        var x = w;
        while (!x.isToplevel()) x = x.parent orelse return x;
        return x;
    }

    pub fn isToplevel(w: *const Widget) bool {
        return w.class.is_toplevel;
    }

    pub fn afterConfigure(w: *Widget, changed: []const usize) ztcl.Error!void {
        if (w.class.configured) |f| try f(w, changed);
    }

    /// Sets flags on this widget and the flags that follow from them. A
    /// new size request changes the layout of each ancestor. Each change
    /// paints the toplevel again.
    pub fn invalidate(w: *Widget, d: Dirty) void {
        w.dirty = w.dirty.merge(d);
        // The App keeps a style flag, so a frame with no change can return at once.
        if (d.style) w.app.style_pending = true;
        if (d.measure) {
            var p = w.parent;
            while (p) |x| : (p = x.parent) x.dirty.measure = true;
        }
        w.toplevel().dirty.paint = true;
        w.app.requestFrame();
    }
};

pub const Class = struct {
    /// "frame"
    command: []const u8,
    /// "Frame"
    tk_class: []const u8,
    is_toplevel: bool = false,
    focusable: bool = false,
    init: ?*const fn (w: *Widget) anyerror!void = null,
    deinit: ?*const fn (w: *Widget) void = null,
    specs: []const options.Spec = &.{},
    /// The requested size from the content, the style, and the options.
    measure: ?*const fn (w: *Widget) geom.Size = null,
    /// Adds the quads of the widget. The origin of the builder is the
    /// top-left corner of the widget.
    paint: ?*const fn (w: *Widget, b: *scene.Builder) anyerror!void = null,
    /// Removes what the class holds in the interpreter and the loop: its
    /// variable traces and its timers. `destroy` calls it one time.
    teardown: ?*const fn (w: *Widget) void = null,
    /// Adds the variable traces of the widget again. `App.maybeCompact` calls it,
    /// because a compact of the interpreter drops the variable traces.
    retrace: ?*const fn (w: *Widget) void = null,
    /// The command word of the variable trace of the class.
    trace_command: []const u8 = "",
    /// The name of the variable that the widget traces, or empty.
    traced_var: ?*const fn (w: *const Widget) []const u8 = null,
    /// A second traced variable (for example `-variable` beside `-textvariable`) and its command word.
    traced_var2: ?*const fn (w: *const Widget) []const u8 = null,
    trace_command2: []const u8 = "",
    /// Space that the class adds inside the border and the padding, for
    /// example the title of a labelframe. The geometry managers keep their
    /// content out of it.
    extra_insets: ?*const fn (w: *Widget) geom.Insets = null,
    /// The accessibility role of the class (section 4.9 of the plan).
    role: []const u8 = "",
    /// True for a `ttk` class: it has `-style`, `state`, and `instate`.
    ttk: bool = false,
    /// A second type that the selectors of the class match: the classic
    /// class of a `ttk` class (`Button` for `TButton`).
    css_base: []const u8 = "",
    /// The value of `-text` while a `-textvariable` supplies it, or null.
    variable_text: ?*const fn (w: *const Widget) ?[]const u8 = null,
    /// Runs one time after the options of the create command, also when it has none.
    created: ?*const fn (w: *Widget) ztcl.Error!void = null,
    /// Runs after `apply` changed options. `changed` has the spec indexes.
    configured: ?*const fn (w: *Widget, changed: []const usize) ztcl.Error!void = null,
    /// A widget subcommand other than `configure` and `cget`. It returns
    /// null when the class does not have the subcommand.
    subcommand: ?*const fn (w: *Widget, it: *ztcl.Interp, argv: []const ztcl.Value) ztcl.Error!?ztcl.Value = null,
    /// The names of the subcommands that `subcommand` has, in order, for the error message.
    extra_subcommands: []const []const u8 = &.{},
    /// The complete list of subcommand names for the error message. It replaces `extra_subcommands`.
    bad_option_list: []const u8 = "",
    /// Runs for each event of the widget before its bindings: the items of a canvas.
    event: ?*const fn (w: *Widget, ev: *const bind.WidgetEvent) void = null,
    /// The pointer shape of a part under the pointer, such as a sash, or
    /// null. It comes before the `-cursor` option.
    cursor: ?*const fn (w: *const Widget) ?@import("platform/platform.zig").Cursor = null,
};

/// The name of a variable in the global namespace, as `-textvariable` reads it.
/// The caller frees the result.
pub fn globalVar(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, name, "::")) return gpa.dupe(u8, name);
    return std.fmt.allocPrint(gpa, "::{s}", .{name});
}

/// The text of a trace script: the command and the path of the widget as one list element.
pub fn traceScript(a: std.mem.Allocator, command: []const u8, path: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, command) catch return "";
    out.append(a, ' ') catch return "";
    ztcl.value.appendElement(a, &out, path, false) catch return "";
    return out.items;
}

/// The command that makes a widget of one class. The class is bound at
/// compile time, so an enter trace that renames or replaces the command
/// cannot change it.
pub fn classCommand(comptime class: *const Class) ztcl.interp.NativeFn {
    return struct {
        fn call(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
            const app = App.of(it);
            app.enter();
            defer app.leave();
            if (argv.len < 2) return it.wrongArgs(class.command ++ " pathName ?-option value ...?");
            const w = try create(app, class, try it.str(argv[1]));
            const pathcopy = try it.alloc().dupe(u8, w.path);
            options.applyEx(w, it, argv[2..], true) catch |e| {
                destroy(w);
                return e;
            };
            if (class.created) |f| f(w) catch |e| {
                destroy(w);
                return e;
            };
            if (!w.alive()) return it.fail("can't create window: it was deleted", .{});
            return .{ .str = pathcopy };
        }
    }.call;
}

/// True for a command that runs `widgetCommand`, also under an execution trace.
fn isWidgetCommand(c: *const ztcl.interp.Command) bool {
    if (c.impl == .native and c.impl.native == widgetCommand) return true;
    const t = c.traces orelse return false;
    const orig = t.orig orelse return false;
    return orig == .native and orig.native == widgetCommand;
}

/// The widget of the command that runs, or null when it is gone. The name
/// is looked up again, because an enter trace can delete or replace the
/// widget, and can run the same call site with another name.
fn commandWidget(it: *ztcl.Interp, argv: []const ztcl.Value, cmd: ?*ztcl.interp.Cmd) ztcl.Error!?*Widget {
    const c: ?*ztcl.interp.Command = it.findCommand(try it.str(argv[0])) orelse if (cmd) |site| site.resolved else null;
    const found = c orelse return null;
    if (!isWidgetCommand(found)) return null;
    const h: *Handle = @ptrCast(@alignCast(found.ctx orelse return null));
    return h.widget;
}

/// The widget command: `.f option ?arg ...?`. The `ctx` of the command is a `Handle`.
pub fn widgetCommand(it: *ztcl.Interp, argv: []const ztcl.Value, cmd: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    const w = (try commandWidget(it, argv, cmd)) orelse return it.fail("invalid command name \"{s}\"", .{try it.str(argv[0])});
    const app = w.app;
    app.enter();
    defer app.leave();
    if (argv.len < 2) {
        return it.fail("wrong # args: should be \"{s} option ?arg ...?\"", .{w.path});
    }
    const sub = try it.str(argv[1]);
    if (sub.len >= 2 and std.mem.startsWith(u8, "configure", sub)) return options.configure(w, it, argv[2..]);
    if (sub.len >= 2 and std.mem.startsWith(u8, "cget", sub)) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} cget option\"", .{w.path});
        return options.cget(w, it, argv[2]);
    }
    if (w.class.subcommand) |f| {
        if (try f(w, it, argv)) |v| return v;
    }
    if (w.class.bad_option_list.len > 0) return it.fail("bad option \"{s}\": must be {s}", .{ sub, w.class.bad_option_list });
    if (w.class.extra_subcommands.len == 0) return it.fail("bad option \"{s}\": must be cget or configure", .{sub});
    var list: std.ArrayList(u8) = .empty;
    const a = it.alloc();
    try list.appendSlice(a, "cget, configure");
    for (w.class.extra_subcommands, 0..) |n, i| {
        try list.appendSlice(a, if (i + 1 == w.class.extra_subcommands.len) ", or " else ", ");
        try list.appendSlice(a, n);
    }
    return it.fail("bad option \"{s}\": must be {s}", .{ sub, list.items });
}

/// Makes a widget and its command. `path` must have an existing parent.
pub fn create(app: *App, class: *const Class, path: []const u8) ztcl.Error!*Widget {
    const it = app.it;
    if (path.len == 0 or path[0] != '.') return it.fail("bad window path name \"{s}\"", .{path});
    const dot = std.mem.lastIndexOfScalar(u8, path, '.').?;
    const leaf = path[dot + 1 ..];
    if (path.len == 1) return it.fail("window name \"\" already exists in parent", .{});
    if (leaf.len == 0 or (dot > 0 and path[dot - 1] == '.')) {
        return it.fail("bad window path name \"{s}\"", .{path});
    }
    const parent_path = if (dot == 0) "." else path[0..dot];
    const parent = app.lookup(parent_path) orelse return it.fail("bad window path name \"{s}\"", .{parent_path});
    if (!parent.alive()) return it.fail("can't create window: parent has been destroyed", .{});
    if (std.ascii.isUpper(leaf[0])) return it.fail("window name starts with an upper-case letter: \"{s}\"", .{leaf});
    if (app.widgets.contains(path)) return it.fail("window name \"{s}\" already exists in parent", .{leaf});
    return try makeNode(app, class, path, parent);
}

/// Makes a node with no path checks. `App.init` uses it for ".".
pub fn makeNode(app: *App, class: *const Class, path: []const u8, parent: ?*Widget) ztcl.Error!*Widget {
    const gpa = app.gpa;
    const w = try gpa.create(Widget);
    errdefer gpa.destroy(w);
    const owned = try gpa.dupe(u8, path);
    errdefer gpa.free(owned);
    // Tk gives a new widget the size 1 by 1 until the first layout.
    w.* = .{ .app = app, .path = owned, .class = class, .tk_class = class.tk_class, .parent = parent, .geom = .{ .w = 1, .h = 1 }, .req = .{ .w = 1, .h = 1 } };
    if (parent == null) w.tk_class = app.root_class;
    if (parent) |p| try p.children.append(gpa, w);
    errdefer if (parent) |p| {
        _ = p.children.pop();
    };
    try app.widgets.put(gpa, owned, w);
    errdefer _ = app.widgets.remove(owned);
    try app.it.register(owned, widgetCommand);
    errdefer {
        _ = app.it.commands.remove(owned);
        app.it.epoch += 1;
    }
    const handle = try gpa.create(Handle);
    handle.* = .{ .widget = w, .next = app.handles };
    app.handles = handle;
    errdefer handle.widget = null;
    w.handle = handle;
    app.it.findCommand(owned).?.ctx = handle;
    try options.initSlots(w, app.it);
    errdefer options.freeSlots(w);
    if (class.init) |f| f(w) catch return error.OutOfMemory;
    if (parent) |p| p.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
    return w;
}

/// The last child that is alive.
fn lastAliveChild(w: *const Widget) ?*Widget {
    var i = w.children.items.len;
    while (i > 0) {
        i -= 1;
        if (w.children.items[i].alive()) return w.children.items[i];
    }
    return null;
}

/// Deletes a widget, its children first, and its command. The order of
/// the steps follows `wish`. The memory stays until the App frees the
/// dead list. A call for a widget that is not alive has no effect.
pub fn destroy(w: *Widget) void {
    if (!w.alive()) return;
    const app = w.app;
    app.enter();
    defer app.leave();
    w.life = .destroying;
    release(w);
    while (lastAliveChild(w)) |c| destroy(c);
    // Each child that is left is destroying in an outer call of this function.
    for (w.children.items) |c| c.parent = null;
    w.children.clearRetainingCapacity();
    removeCommand(w);
    app.it.epoch += 1;
    if (!app.closing) {
        var ev: bind.WidgetEvent = .{ .type = .destroy, .widget = w, .serial = 0 };
        bind.deliver(app, &ev);
    }
    finish(w);
}

/// Removes each reference to the widget from the input, focus, animation, and layout state.
fn release(w: *Widget) void {
    const app = w.app;
    app.dispatch.forget(w);
    app.text_input.forget(w);
    focus.forget(app, w);
    anim.forget(app, w);
    @import("grab.zig").forget(app, w);
    layout.destroyed(w);
}

/// The last step of `destroy`: from `destroying` to `dead`.
fn finish(w: *Widget) void {
    const app = w.app;
    // A Destroy binding can use `grid` on the widget again.
    release(w);
    if (w.class.teardown) |f| f(w);
    @import("scroll.zig").forget(w);
    app.bindings.removeTag(w.path);
    @import("grab.zig").dropTooltip(app, w.path);
    _ = app.widgets.remove(w.path);
    app.styles.forget(w);
    if (w.parent) |p| {
        var i = p.children.items.len;
        while (i > 0) {
            i -= 1;
            if (p.children.items[i] == w) {
                _ = p.children.orderedRemove(i);
                break;
            }
        }
        p.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
    }
    if (app.root == w) app.root = null;
    w.parent = null;
    w.life = .dead;
    w.next_dead = app.dead.head;
    app.dead.head = w;
    app.dead.len += 1;
}

/// Ends the command of the widget. The handle gets null at once. The key
/// of the path goes at once. A key from `rename` or `namespace import` goes
/// at the outermost `App.leave`, so a delete of a tree walks the table one time.
fn removeCommand(w: *Widget) void {
    const app = w.app;
    const it = app.it;
    const h = w.handle orelse return;
    h.widget = null;
    w.handle = null;
    if (it.commands.get(w.path)) |c| {
        if (c.ctx == @as(?*anyopaque, h)) _ = it.commands.remove(w.path);
    }
    app.keys_pending = true;
}

/// Removes each command key of the handles that lost their widget.
pub fn dropGoneKeys(app: *App) void {
    if (!app.keys_pending) return;
    app.keys_pending = false;
    const it = app.it;
    // A remove during the walk is safe: the table does not move, and the walk needs no memory.
    var iter = it.commands.iterator();
    while (iter.next()) |e| {
        if (!isWidgetCommand(e.value_ptr.*)) continue;
        const h: *Handle = @ptrCast(@alignCast(e.value_ptr.*.ctx orelse continue));
        if (h.widget == null) _ = it.commands.remove(e.key_ptr.*);
    }
    it.epoch += 1;
}

pub fn free(w: *Widget) void {
    const gpa = w.app.gpa;
    if (w.class.deinit) |f| f(w);
    options.freeSlots(w);
    for (w.classes.items) |cl| gpa.free(cl);
    w.classes.deinit(gpa);
    w.freeBindtags();
    w.children.deinit(gpa);
    w.placed.deinit(gpa);
    gpa.free(w.path);
    gpa.destroy(w);
}
