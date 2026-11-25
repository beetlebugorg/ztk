//! One ztk instance on one interpreter. The App owns the widget tree and
//! the table of widget paths. `init` adds the commands of ztk to the
//! interpreter and makes the root widget ".". The field `user` of the
//! interpreter holds the App, so a native command can find it.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const num = @import("num.zig");
const compact = @import("compact.zig");
const ztcl = @import("ztcl");
const widget = @import("widget.zig");
const style_mod = @import("style.zig");
const cmds = @import("cmds.zig");
const loop = @import("loop.zig");
const layout = @import("layout.zig");
const grid = @import("grid.zig");
const geom = @import("geom.zig");
const paint = @import("paint.zig");
const scene_mod = @import("scene.zig");
const wm_mod = @import("wm.zig");
const render_thread = @import("render/thread.zig");
const anim = @import("anim.zig");
const stats_mod = @import("stats.zig");
const bind = @import("bind.zig");
const dispatch = @import("dispatch.zig");
const focus_mod = @import("focus.zig");
const font_mod = @import("text/font.zig");
const atlas_mod = @import("text/atlas.zig");
const event = @import("event.zig");
const platform_mod = @import("platform/platform.zig");
const Platform = platform_mod.Platform;
const Widget = widget.Widget;
const Class = widget.Class;

pub const Options = struct {
    /// The class of ".". Tk uses the program name with a capital letter.
    root_class: []const u8 = "Ztk",
    /// The result of `winfo name .`.
    app_name: []const u8 = "ztk",
    platform: Platform,
    /// Where the trace of a background error goes. Null means stderr.
    err_output: ?ztcl.Output = null,
    /// True for the dark scheme.
    dark: bool = false,
    /// The folder that `ztk::style load` reads. Null: the command is not allowed.
    style_root: ?[]const u8 = null,
    /// For `ztk::style load`.
    io: ?std.Io = null,
    /// False: each transition has the duration 0. `ZTK_NO_ANIMATION=1` sets it in the program.
    animations: bool = true,
    /// The time of the process start on the system clock, for the time to the first frame.
    start_us: i64 = 0,
    /// The arena size of the interpreter that triggers a compact.
    compact_threshold: usize = 8 << 20,
    /// How the frames are drawn. A backend that cannot draw on another thread always uses `inline_draw`.
    render_mode: render_thread.Mode = .inline_draw,
    /// What the command `exit` calls. Null: the command gives an error.
    on_exit: ?*const fn (code: u8) noreturn = null,
};

/// The largest side of a window in logical pixels. A larger request gets this size.
pub const max_window: i32 = 8192;

/// The largest side of a frame in device pixels.
const max_frame: u32 = 16384;

pub const App = struct {
    gpa: std.mem.Allocator,
    it: *ztcl.Interp,
    root: ?*Widget = null,
    widgets: std.StringHashMapUnmanaged(*Widget) = .empty,
    classes: std.StringHashMapUnmanaged(*const Class) = .empty,
    /// Each command handle. `deinit` frees them.
    handles: ?*widget.Handle = null,
    /// True when a handle lost its widget and `leave` has keys to remove.
    keys_pending: bool = false,
    /// The function of the command `trace` at the start. A compact needs it.
    trace_native: ?ztcl.interp.NativeFn = null,
    /// Widgets in the state `dead`. `leave` frees them.
    dead: struct { head: ?*Widget = null, len: usize = 0 } = .{},
    root_class: []const u8,
    app_name: []const u8,
    /// The count of open `enter` calls. The dead list is freed at 0.
    callback_depth: u32 = 0,
    /// Logical pixels for each point. `tk scaling` sets it.
    scaling: f64 = 96.0 / 72.0,
    platform: Platform,
    /// The window of ".". Null after "." is deleted.
    window: ?*platform_mod.Window = null,
    loop: loop.Loop,
    err_output: ?ztcl.Output,
    styles: style_mod.StyleSet,
    env: style_mod.Env = .{},
    style_root: ?[]const u8 = null,
    io: ?std.Io = null,
    on_exit: ?*const fn (code: u8) noreturn = null,
    /// The generation of the style set at the last restyle.
    style_gen: u32 = 0,
    /// The queue of backend events, in order. The events before
    /// `event_head` are delivered. A nested `update` continues at the
    /// head, so each event is delivered one time and in order.
    events: std.ArrayListUnmanaged(event.Event) = .empty,
    event_head: usize = 0,
    fonts: font_mod.Fonts,
    atlas: atlas_mod.Atlas,
    /// The render thread, or the inline draw. It owns the renderer and the present step.
    render: *render_thread.RenderThread = undefined,
    /// True after `render` is valid, until `deinit` frees it.
    render_ready: bool = false,
    wm: wm_mod.State = .{},
    bindings: bind.Table,
    focus: focus_mod.Focus = .{},
    dispatch: dispatch.State = .{},
    /// Counts up when a compact of the interpreter makes compiled scripts invalid.
    script_gen: u32 = 0,
    /// True while `runScript` runs one top-level command.
    script_top: bool = false,
    /// True while the App is deleted: no Destroy binding runs.
    closing: bool = false,
    /// The count of frames that were drawn.
    frames: u64 = 0,
    /// `run` returns after this count of frames.
    max_frames: ?u64 = null,
    /// The wall clock for the statistics, in microseconds.
    wall: *const fn () i64 = wallNow,
    animations: bool = true,
    anims: std.ArrayListUnmanaged(anim.Anim) = .empty,
    key_anims: std.ArrayListUnmanaged(anim.KeyAnim) = .empty,
    /// The animations of `ztk::animate`.
    opt_anims: @import("animate.zig").State = .{},
    /// True: each animation shows its end state at once (`ztk::animate reduce`).
    reduce_motion: bool = false,
    /// While set, `anim.shown` gives this style for this widget. The paint uses it
    /// to paint the start of a transition for the render thread.
    /// The frame that the paint fills, for the transitions of the render thread.
    anim_frame: ?*scene_mod.Frame = null,
    paint_override: ?struct { widget: *const Widget, style: *const style_mod.Style } = null,
    anim_last_us: i64 = -1,
    anim_requested_us: i64 = -1,
    stats: stats_mod.Stats = .{},
    start_us: i64 = 0,
    compact_threshold: usize = 8 << 20,
    /// The arena size after the last compact, or at the start.
    compact_base: usize = 0,
    /// Counts the arrange calls of the layout pass, for the tests.
    arrange_count: u64 = 0,
    /// True when a widget has the style flag. `restyle` clears it.
    style_pending: bool = true,
    /// True from a request for a frame until the frame event arrives.
    frame_requested: bool = false,

    pub fn init(gpa: std.mem.Allocator, it: *ztcl.Interp, opts: Options) !*App {
        const app = try create(gpa, it, opts);
        // From here `deinit` owns each part, so no other cleanup runs.
        app.start(opts) catch |e| {
            app.deinit();
            return e;
        };
        return app;
    }

    /// Runs the native `trace` command. The name is not used, so a script that
    /// renames or replaces `trace` does not change the traces of ztk.
    pub fn callTrace(app: *App, words: []const ztcl.Value) ztcl.Error!ztcl.Value {
        const f = app.trace_native orelse return app.it.fail("the trace command is not available", .{});
        return f(app.it, words, null);
    }

    /// Makes the App value. On an error each part that it made is freed.
    fn create(gpa: std.mem.Allocator, it: *ztcl.Interp, opts: Options) !*App {
        const app = try gpa.create(App);
        errdefer gpa.destroy(app);
        var fonts = try font_mod.Fonts.init(gpa);
        errdefer fonts.deinit();
        const rc = try gpa.dupe(u8, opts.root_class);
        errdefer gpa.free(rc);
        const an = try gpa.dupe(u8, opts.app_name);
        errdefer gpa.free(an);
        // The last step that can fail, so this copy needs no cleanup.
        const root_dir: ?[]const u8 = if (opts.style_root) |r| try gpa.dupe(u8, r) else null;
        app.* = .{ .gpa = gpa, .it = it, .root_class = rc, .app_name = an, .platform = opts.platform, .loop = undefined, .err_output = opts.err_output, .styles = style_mod.StyleSet.init(gpa), .io = opts.io, .on_exit = opts.on_exit, .animations = opts.animations, .start_us = opts.start_us, .compact_threshold = opts.compact_threshold, .fonts = fonts, .atlas = atlas_mod.Atlas.init(gpa), .bindings = bind.Table.init(gpa) };
        app.env.dark = opts.dark;
        app.style_root = root_dir;
        app.loop = loop.Loop.init(app, app.platform.clock());
        return app;
    }

    /// Adds the commands, the root widget, the render thread, and the theme.
    fn start(app: *App, opts: Options) !void {
        const gpa = app.gpa;
        if (app.it.findCommand("trace")) |c| {
            if (c.impl == .native) app.trace_native = c.impl.native;
        }
        try cmds.register(app);
        {
            const mode: render_thread.Mode = if (app.platform.thread_safe_draw and opts.io != null) opts.render_mode else .inline_draw;
            app.render = try render_thread.RenderThread.init(gpa, opts.io orelse undefined, mode, app.platform.target(app.window.?));
            app.render_ready = true;
        }
        _ = try app.styles.add(.base, "base", @embedFile("themes/base.css"));
        _ = try app.styles.add(.theme, "modern", @embedFile("themes/modern.css"));
        _ = try app.styles.add(.platform, "modern-linux", @embedFile("themes/modern-linux.css"));
    }

    pub fn deinit(app: *App) void {
        app.closing = true;
        if (app.root) |r| widget.destroy(r);
        // A widget that has no root (a failed init) still needs a free.
        // The window goes away here, after the render thread finished its frames.
        app.sweepAll();
        if (app.render_ready) app.render.deinit();
        app.render_ready = false;
        app.widgets.deinit(app.gpa);
        app.classes.deinit(app.gpa);
        while (app.handles) |h| {
            app.handles = h.next;
            app.gpa.destroy(h);
        }
        if (app.it.user == @as(?*anyopaque, app)) app.it.user = null;
        app.loop.deinit();
        app.styles.deinit();
        app.bindings.deinit();
        app.anims.deinit(app.gpa);
        anim.deinit(app);
        app.opt_anims.deinit(app.gpa);
        app.fonts.deinit();
        app.atlas.deinit();
        app.wm.deinit(app.gpa);
        if (app.style_root) |r| app.gpa.free(r);
        app.events.deinit(app.gpa);
        app.gpa.free(app.root_class);
        app.gpa.free(app.app_name);
        app.gpa.destroy(app);
    }

    /// The App of an interpreter. It reads the `user` field of the
    /// interpreter, which a script cannot change.
    pub fn of(it: *ztcl.Interp) *App {
        return @ptrCast(@alignCast(it.user.?));
    }

    /// The widget of a path, when it is alive.
    pub fn find(app: *App, path: []const u8) ?*Widget {
        const w = app.widgets.get(path) orelse return null;
        return if (w.alive()) w else null;
    }

    /// The widget of a path, also when it is in the state `destroying`.
    pub fn lookup(app: *App, path: []const u8) ?*Widget {
        return app.widgets.get(path);
    }

    /// Starts a stretch of Zig code that holds widget pointers across a
    /// script. Each path into widget code calls it. A widget that a script
    /// deletes stays in memory until the outermost `leave`.
    pub fn enter(app: *App) void {
        app.callback_depth += 1;
    }

    /// Ends what `enter` started. The outermost `leave` frees the dead widgets.
    /// Call it with `defer`, so that an error path also runs it.
    pub fn leave(app: *App) void {
        app.callback_depth -= 1;
        if (app.callback_depth != 0) return;
        widget.dropGoneKeys(app);
        app.sweepAll();
    }

    /// Reads a file for `ztk::style load`. The real path of the file, with each
    /// symbolic link resolved, must be inside the real path of the style folder.
    pub fn readFile(app: *App, path: []const u8, a: std.mem.Allocator) ![]u8 {
        const io = app.io orelse return error.NoIo;
        const root = app.style_root orelse return error.NoIo;
        const dir = std.Io.Dir.cwd();
        const real_root = try dir.realPathFileAlloc(io, root, a);
        const real = try dir.realPathFileAlloc(io, path, a);
        const inside = real.len > real_root.len and std.mem.startsWith(u8, real, real_root) and real[real_root.len] == '/';
        if (!inside) return error.OutsideStyleFolder;
        return dir.readFileAlloc(io, real, a, .limited(1 << 20));
    }

    /// Makes the style of a widget valid, and the styles of its ancestors first.
    pub fn ensureStyle(app: *App, w: *widget.Widget) void {
        if (app.styles.generation != app.style_gen) app.markAllStyle();
        if (!w.dirty.style) return;
        if (w.parent) |p| app.ensureStyle(p);
        app.computeOne(w);
    }

    fn markAllStyle(app: *App) void {
        app.style_gen = app.styles.generation;
        var it = app.widgets.valueIterator();
        while (it.next()) |w| w.*.dirty.style = true;
    }

    fn computeOne(app: *App, w: *widget.Widget) void {
        const parent_style: ?*const style_mod.Style = if (w.parent) |p| &p.style else null;
        const new = app.styles.compute(w, null, parent_style, app.env);
        const now = app.platform.nowUs();
        if (!new.eql(anim.target(app, w)) or !w.styled) {
            const old = anim.target(app, w).*;
            w.style = new;
            // A widget that has no style yet does not animate.
            if (w.styled) anim.start(app, w, &old, &new, now) catch {};
            w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
            for (w.children.items) |c| c.dirty.style = true;
            anim.keyframes(app, w, now);
        }
        w.dirty.style = false;
        w.styled = true;
    }

    /// Computes the style of each widget that has the style flag. A
    /// change of the style marks the measure, layout, and paint flags of
    /// the widget and the style flag of its children.
    pub fn restyle(app: *App) void {
        app.style_pending = false;
        if (app.styles.generation != app.style_gen) app.markAllStyle();
        if (app.root) |r| app.restyleNode(r);
    }

    fn restyleNode(app: *App, w: *widget.Widget) void {
        if (w.dirty.style) app.computeOne(w);
        for (w.children.items) |c| app.restyleNode(c);
    }

    /// The widget that gets key events: the focus widget, or the toplevel.
    pub fn keyTarget(app: *App) ?*widget.Widget {
        if (app.focus.current) |c| if (c.alive()) return c;
        return app.root;
    }

    /// Asks the backend for one `frame` event, unless one is pending.
    pub fn requestFrame(app: *App) void {
        if (app.frame_requested) return;
        const win = app.window orelse return;
        app.frame_requested = true;
        app.platform.requestFrame(win);
    }

    pub fn frameError(app: *App, e: anyerror) void {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "ztk: frame failed: {s}\n", .{@errorName(e)}) catch return;
        app.writeError(msg);
    }

    /// Asks the backend for a window size, and takes the size at once when
    /// the backend gives it at once.
    pub fn setWindowSize(app: *App, requested: geom.Size) void {
        const win = app.window orelse return;
        const size: geom.Size = .{ .w = std.math.clamp(requested.w, 1, max_window), .h = std.math.clamp(requested.h, 1, max_window) };
        const root = app.root orelse return;
        app.platform.vtable.requestSize(app.platform.ptr, win, size);
        if (win.size.w != root.geom.w or win.size.h != root.geom.h) {
            root.geom = .{ .x = 0, .y = 0, .w = win.size.w, .h = win.size.h };
            root.invalidate(.{ .style = false, .measure = false, .layout = true, .paint = true });
        }
    }

    fn paintNode(app: *App, w: *widget.Widget, b: *scene_mod.Builder) anyerror!void {
        if (!w.mapped) return;
        b.pushOffset(w.geom.x, w.geom.y);
        defer b.popOffset();
        const ov = paint.overflow(&w.style);
        b.pushClip(.{ .x = -ov, .y = -ov, .w = w.geom.w + 2 * ov, .h = w.geom.h + 2 * ov });
        defer b.popClip();
        if (w.class.paint) |f| try app.paintOwn(w, b, f);
        b.pushClip(.{ .x = 0, .y = 0, .w = w.geom.w, .h = w.geom.h });
        defer b.popClip();
        for (w.children.items) |c| try app.paintNode(c, b);
    }

    /// Paints the quads of one widget. A widget with a transition of the
    /// paint is painted at the end and at the start of the transition, and
    /// the frame gets both lists, so the render thread can move the quads
    /// for the time that it draws. When the two lists differ in their
    /// count, the widget is painted once with the shown style.
    fn paintOwn(app: *App, w: *widget.Widget, b: *scene_mod.Builder, f: *const fn (w: *widget.Widget, b: *scene_mod.Builder) anyerror!void) anyerror!void {
        const a = anim.transitionOf(app, w) orelse return f(w, b);
        if (a.layout or app.anim_frame == null) return f(w, b);
        const fr = app.anim_frame.?;
        const quads = &b.scene.quads;
        const first = quads.items.len;
        app.paint_override = .{ .widget = w, .style = &a.to };
        defer app.paint_override = null;
        try f(w, b);
        const n_to = quads.items.len - first;
        const mark = fr.anim_quads.items.len;
        try fr.anim_quads.appendSlice(app.gpa, quads.items[first..]);
        quads.shrinkRetainingCapacity(first);
        app.paint_override = .{ .widget = w, .style = &a.from };
        try f(w, b);
        const n_from = quads.items.len - first;
        if (n_from != n_to or n_to == 0) {
            fr.anim_quads.shrinkRetainingCapacity(mark);
            quads.shrinkRetainingCapacity(first);
            app.paint_override = null;
            return f(w, b);
        }
        // The list holds the start quads, then the end quads.
        try fr.anim_quads.insertSlice(app.gpa, mark, quads.items[first..]);
        // One timing moves all quads: the property with the longest time.
        var spec: style_mod.TransSpec = .{};
        for (a.spec.props) |p| if (p.active() and p.totalUs() > spec.totalUs()) {
            spec = p;
        };
        try fr.anims.append(app.gpa, .{
            .first = @intCast(first),
            .count = @intCast(n_to),
            .from = @intCast(mark),
            .start_us = a.start_us,
            .delay_us = @as(i64, spec.delay_ms) * 1000,
            .len_us = spec.totalUs() - @as(i64, spec.delay_ms) * 1000,
            .timing = spec.timing,
        });
    }

    /// Delivers Map, Unmap, and Configure events for each widget whose
    /// mapped flag or geometry changed since the last report.
    fn reportGeometry(app: *App, w: *widget.Widget) void {
        if (!w.alive()) return;
        if (w.mapped != w.cfg_mapped) {
            w.cfg_mapped = w.mapped;
            var ev: bind.WidgetEvent = .{ .type = if (w.mapped) .map else .unmap, .widget = w };
            bind.deliver(app, &ev);
        }
        if (!w.alive()) return;
        const g = w.geom;
        const c = w.cfg_geom;
        if (g.x != c.x or g.y != c.y or g.w != c.w or g.h != c.h) {
            w.cfg_geom = g;
            var ev: bind.WidgetEvent = .{ .type = .configure, .widget = w, .x = g.x, .y = g.y, .width = g.w, .height = g.h };
            bind.deliver(app, &ev);
        }
        var i: usize = 0;
        while (i < w.children.items.len) : (i += 1) app.reportGeometry(w.children.items[i]);
    }

    fn colorF(c: geom.Color) [4]f32 {
        return .{
            @as(f32, @floatFromInt(c.r)) / 255,
            @as(f32, @floatFromInt(c.g)) / 255,
            @as(f32, @floatFromInt(c.b)) / 255,
            @as(f32, @floatFromInt(c.a)) / 255,
        };
    }

    /// Runs the stages that the dirty flags ask for, for one toplevel:
    /// style, measure and layout, the window size, paint, and draw. It
    /// returns true when it drew. With no dirty flag it does nothing.
    pub fn frame(app: *App, top: *widget.Widget) !bool {
        app.enter();
        defer app.leave();
        const win = app.window orelse return false;
        const now = app.platform.nowUs();
        const opt_running = @import("animate.zig").tick(app, now);
        const animating = anim.tick(app, now) or opt_running;
        if (!top.dirty.any() and !app.style_pending and app.styles.generation == app.style_gen) return false;
        const wall = &app.wall;
        app.stats.begin(.style, wall.*());
        app.restyle();
        app.stats.end(.style, wall.*());
        app.stats.begin(.layout, wall.*());
        _ = layout.run(top);
        app.stats.end(.layout, wall.*());
        if (app.wm.geometry == null and layout.propagates(top)) {
            const m = app.wm.minsize;
            const x = app.wm.maxsize;
            const want: geom.Size = .{
                .w = std.math.clamp(top.req.w, @max(m.w, 1), @max(x.w, m.w, 1)),
                .h = std.math.clamp(top.req.h, @max(m.h, 1), @max(x.h, m.h, 1)),
            };
            if (want.w != app.wm.last_req.w or want.h != app.wm.last_req.h) {
                app.wm.last_req = want;
                app.setWindowSize(want);
                _ = layout.run(top);
            }
        }
        top.dirty.style = false;
        app.reportGeometry(top);
        // A Configure or Map binding can delete the toplevel.
        if (!top.alive()) return false;
        if (app.wm.withdrawn or !top.dirty.paint) {
            top.dirty.measure = false;
            top.dirty.layout = false;
            return false;
        }
        const scale = win.scale;
        const dw0: u32 = @intCast(@max(num.pxRound(@as(f64, @floatFromInt(top.geom.w)) * scale), 0));
        const dh0: u32 = @intCast(@max(num.pxRound(@as(f64, @floatFromInt(top.geom.h)) * scale), 0));
        const dw = @min(dw0, max_frame);
        const dh = @min(dh0, max_frame);
        app.stats.begin(.paint, wall.*());
        const fr = app.render.back();
        fr.reset(app.gpa);
        fr.scene.reset(@max(dw, 1), @max(dh, 1));
        fr.scene.clear = colorF(top.style.background);
        var b = scene_mod.Builder.init(app.gpa, &fr.scene, scale);
        fr.time_us = now;
        app.anim_frame = fr;
        defer app.anim_frame = null;
        try app.paintNode(top, &b);
        try app.atlas.takePatches(app.gpa, &fr.patches);
        app.stats.end(.paint, wall.*());
        app.stats.begin(.render, wall.*());
        app.render.submit();
        app.stats.end(.render, wall.*());
        top.dirty = widget.Dirty.none;
        app.frames += 1;
        if (app.frames == 1) app.stats.first_frame_us = wall.*() - app.start_us;
        app.stats.frameDone(wall.*());
        // An animation asks for the next frame.
        // The time must move on, so a frame at the same time (a manual clock) does not loop.
        if (animating and now != app.anim_requested_us) {
            app.anim_requested_us = now;
            app.requestFrame();
        }
        return true;
    }

    fn wallNow() i64 {
        return loop.system_clock.now(null);
    }

    /// See `compact.zig`. A compact makes each compiled script invalid, so
    /// `script_gen` counts up.
    pub fn maybeCompact(app: *App) bool {
        return compact.maybe(app);
    }

    /// Adds the variable traces of each widget again. A compact of the
    /// interpreter does not keep them.
    pub fn retraceAll(app: *App) void {
        // A script can replace `trace`, so the table can change during the walk.
        app.enter();
        defer app.leave();
        var list: std.ArrayListUnmanaged(*Widget) = .empty;
        defer list.deinit(app.gpa);
        list.ensureTotalCapacity(app.gpa, app.widgets.count()) catch return;
        var iter = app.widgets.valueIterator();
        while (iter.next()) |w| list.appendAssumeCapacity(w.*);
        for (list.items) |w| {
            if (w.alive()) if (w.class.retrace) |f| f(w);
        }
    }

    /// The scene of the last frame that was drawn. In threaded mode, call it after `update`.
    pub fn lastScene(app: *App) *const scene_mod.Scene {
        return &app.render.lastFrame().scene;
    }

    /// Runs frames and passes until no work is left, as `update` needs.
    pub fn flush(app: *App) ztcl.Error!void {
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            const root = app.root orelse return;
            const drew = app.frame(root) catch |e| blk: {
                app.frameError(e);
                break :blk false;
            };
            const worked = try app.pass();
            if (!drew and !worked) return;
        }
    }

    /// True when a wait can end: a timer, an idle entry, or a live backend exists.
    pub fn canWait(app: *App) bool {
        return app.platform.live or app.loop.nextTimeoutUs() != null;
    }

    fn handleEvent(app: *App, ev: event.Event) void {
        // A window that is gone has no events. Compare the pointer only.
        const win = app.window orelse return;
        if (ev.window() != win) return;
        switch (ev) {
            .resize => |r| if (app.root) |root| {
                // A backend can report any size.
                root.geom.w = std.math.clamp(r.size.w, 1, max_window);
                root.geom.h = std.math.clamp(r.size.h, 1, max_window);
                root.invalidate(.{ .style = false, .measure = false, .layout = true, .paint = true });
            },
            .close => if (app.root) |root| {
                if (app.wm.delete_script) |script| {
                    const copy = app.gpa.dupe(u8, script) catch return;
                    defer app.gpa.free(copy);
                    app.callback(copy);
                } else {
                    widget.destroy(root);
                }
            },
            .frame => {
                app.frame_requested = false;
                if (app.root) |root| _ = app.frame(root) catch |e| app.frameError(e);
            },
            .focus => |f| focus_mod.windowFocus(app, f.focused),
            .scale => if (app.root) |root| root.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true }),
            .motion, .button, .leave, .key => dispatch.handle(app, ev),
            else => {},
        }
    }

    fn pass(app: *App) ztcl.Error!bool {
        app.enter();
        defer app.leave();
        app.platform.poll(app.gpa, &app.events) catch return error.OutOfMemory;
        dispatch.collapse(&app.events, app.event_head);
        const had_events = app.event_head < app.events.items.len;
        app.stats.begin(.events, app.wall());
        while (app.event_head < app.events.items.len) {
            // Copy the event: a callback can poll and move the queue.
            const ev = app.events.items[app.event_head];
            app.event_head += 1;
            app.handleEvent(ev);
        }
        app.events.clearRetainingCapacity();
        app.event_head = 0;
        app.stats.end(.events, app.wall());
        const timers = try app.loop.runTimers();
        var ran = had_events or timers;
        if (!ran) ran = try app.loop.runIdle();
        return ran;
    }

    /// One pass: window events, then due timers, then idle entries when
    /// the first two did no work. With `wait`, it blocks until work exists.
    /// Gives false when it did no work.
    pub fn doOneEvent(app: *App, wait: bool) ztcl.Error!bool {
        if (try app.pass()) return true;
        if (!wait) return false;
        const timeout = app.loop.nextTimeoutUs();
        if (timeout == null and !app.platform.live) return false;
        app.platform.wait(timeout);
        return app.pass();
    }

    /// Runs passes until `.` is deleted, or until no work can come.
    pub fn run(app: *App) ztcl.Error!void {
        while (app.root != null) {
            if (app.max_frames) |m| if (app.frames >= m) return;
            _ = app.maybeCompact();
            const worked = try app.doOneEvent(true);
            if (!worked and !app.canWait()) return;
        }
    }

    /// Runs the main script one top-level command at a time. A `vwait` or
    /// `tkwait` that is a top-level command runs here, with no script on
    /// the stack, so the loop can compact. A compact makes the compiled
    /// form invalid, so the parser starts again after the wait.
    pub fn runScript(app: *App, text: []const u8) ztcl.Error!void {
        const it = app.it;
        var pos: usize = 0;
        var line: u32 = 1;
        while (true) {
            const src = try it.alloc().dupe(u8, text[pos..]);
            var p: ztcl.interp.Parser = .{ .a = it.alloc(), .src = src, .line = line };
            const s = p.parseScript(false) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TclError => {
                    it.error_line = p.line;
                    return it.fail("{s}", .{p.message});
                },
            };
            var again = false;
            for (s.cmds, 0..) |*c, i| {
                var one: ztcl.interp.Script = .{ .cmds = s.cmds[i .. i + 1] };
                app.script_top = true;
                const done = evalTopCommand(it, &one);
                app.script_top = false;
                if (try done) return;
                if (app.loop.parked != null) {
                    const end = @intFromPtr(c.text.ptr) + c.text.len - @intFromPtr(src.ptr);
                    pos += end;
                    line += @intCast(std.mem.count(u8, src[0..end], "\n"));
                    if (!try app.loop.runParked()) return;
                    again = true;
                    break;
                }
            }
            if (!again) return;
        }
    }

    /// Runs one top-level command. Gives true when a `return` ended the script.
    fn evalTopCommand(it: *ztcl.Interp, one: *ztcl.interp.Script) ztcl.Error!bool {
        ztcl.value.precision = it.precision;
        _ = it.evalScript(one) catch |e| {
            const final: ztcl.Error = switch (e) {
                error.TclReturn => switch (it.ret_code) {
                    .ok => return true,
                    .@"error" => error.TclError,
                    .@"break", .@"continue" => it.fail("invoked \"{s}\" outside of a loop", .{@tagName(it.ret_code)}),
                    else => it.fail("command returned bad code: {d}", .{@intFromEnum(it.ret_code)}),
                },
                error.TclCustom => it.fail("command returned bad code: {d}", .{it.custom_code}),
                error.TclBreak => it.fail("invoked \"break\" outside of a loop", .{}),
                error.TclContinue => it.fail("invoked \"continue\" outside of a loop", .{}),
                else => e,
            };
            if (final == error.TclError) try it.finishError();
            return final;
        };
        return false;
    }

    /// Runs a callback script at the global level. An error goes to the
    /// background error handler.
    pub fn callback(app: *App, script: []const u8) void {
        const it = app.it;
        const saved_frame = it.frame;
        const saved_ns = it.ns;
        const saved_result = it.result;
        it.frame = &it.global;
        it.ns = "";
        app.enter();
        defer {
            it.frame = saved_frame;
            it.ns = saved_ns;
            it.result = saved_result;
            app.leave();
        }
        _ = it.eval(script) catch |e| app.backgroundError(e);
    }

    /// Calls `bgerror` with the message, or writes the trace.
    pub fn backgroundError(app: *App, e: ztcl.Error) void {
        const it = app.it;
        if (e != error.TclError) return;
        it.finishError() catch return;
        const msg = it.result;
        if (it.findCommand("bgerror") != null) {
            if (it.callWords(&.{ .{ .str = "bgerror" }, msg })) |_| return else |_| {}
            it.finishError() catch return;
        }
        const info = it.getVarPlain("::errorInfo") catch it.result;
        const text = it.str(info) catch return;
        app.writeError(text);
        app.writeError("\n");
    }

    fn writeError(app: *App, text: []const u8) void {
        if (app.err_output) |o| o.write(o.ctx, text) else @import("sys/host.zig").writeStderr(text);
    }

    fn sweepAll(app: *App) void {
        while (app.dead.head) |w| {
            app.dead.head = w.next_dead;
            app.dead.len -= 1;
            widget.free(w);
        }
    }
};
