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
const animate_mod = @import("animate.zig");
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
    /// True: `ztk::hotkey` can register global shortcuts. The ztk program
    /// sets it with `--allow hotkey`.
    hotkeys: bool = false,
    /// What the command `exit` calls. Null: the command gives an error.
    on_exit: ?*const fn (code: u8) noreturn = null,
};

/// The largest side of a window in logical pixels. A larger request gets this size.
pub const max_window: i32 = 8192;

/// The largest side of a frame in device pixels.
const max_frame: u32 = 16384;

pub const PartMove = union(enum) {
    none,
    one: struct { anim: scene_mod.FrameAnim, now: f32 },
    /// Parts move with other timings.
    mixed,
    /// `paintOwn` paints the stops: the parts note nothing.
    blocked,
};

/// The window, the renderer, and the window manager state of a toplevel
/// other than ".". The `data` of the toplevel widget holds it.
pub const Top = struct {
    win: *platform_mod.Window,
    render: *render_thread.RenderThread,
    wm: wm_mod.State = .{},
    frame_requested: bool = false,
    /// The atlas takes that the surface of the window has (`Atlas.takePatchesFor`).
    atlas_seen: u32 = atlas_mod.Atlas.seen_none,
};

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
    /// The themes and the settings of `ttk::style`.
    ttk: @import("ttk/style.zig").Data = .{},
    /// The ids of the theme sheet and the platform sheet (0: none), and the look.
    theme_sheet: u32 = 0,
    platform_sheet: u32 = 0,
    /// The sheet of `--system-accent` (0: none).
    accent_sheet: u32 = 0,
    classic_look: bool = false,
    env: style_mod.Env = .{},
    /// The state of `ztk::debug`.
    dbg: @import("debug.zig").State = .{},
    style_root: ?[]const u8 = null,
    io: ?std.Io = null,
    on_exit: ?*const fn (code: u8) noreturn = null,
    hotkeys_allowed: bool = false,
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
    /// Render threads with no window, for the next toplevels. A threaded
    /// App starts one at its start, so the first toplevel opens with no
    /// thread start, and a toplevel that closes gives its thread back.
    render_pool: std.ArrayListUnmanaged(*render_thread.RenderThread) = .empty,
    key_anims: std.ArrayListUnmanaged(anim.KeyAnim) = .empty,
    /// The animations of `ztk::animate`.
    opt_anims: @import("animate.zig").State = .{},
    /// True: each animation shows its end state at once (`ztk::animate reduce`).
    reduce_motion: bool = false,
    /// While set, `anim.shown` gives this style for this widget. The paint uses it
    /// to paint the start of a transition for the render thread.
    /// True when a paint asks for the next frame: a part of a widget moves.
    anim_more: bool = false,
    /// The time of the frame that set `anim_more`.
    anim_more_us: i64 = -1,
    /// The frame that the paint fills, for the transitions of the render thread.
    anim_frame: ?*scene_mod.Frame = null,
    paint_override: ?struct { widget: *const Widget, style: *const style_mod.Style } = null,
    /// The moves of parts in the paint of one widget, for `paintOwn`.
    part_move: PartMove = .none,
    /// True while `paintOwn` paints the parts at the end of their moves.
    part_end: bool = false,
    /// The drag of a scrollbar thumb, for the view that it scrolls.
    scroll_link: ?@import("scroll.zig").Link = null,
    /// The contents of the clipboard (`clipboard append`).
    clipboard: @import("clipboard.zig").Store = .{},
    named_fonts: @import("fontcmd.zig").Store = .{},
    option_db: @import("optiondb.zig").Store = .{},
    /// The sequences of the virtual events of `event add`.
    virtual_events: std.ArrayListUnmanaged(bind.VirtualDef) = .empty,
    /// The input method: what the backend has, and the composition text.
    text_input: @import("textinput.zig").State = .{},
    /// The icons of `ztk::tray`.
    trays: @import("tray.zig").State = .{},
    /// The progress and the badge of `ztk::taskbar`.
    taskbar: @import("platform/platform.zig").Taskbar = .{},
    /// The shortcuts of `ztk::hotkey`.
    hotkeys: @import("hotkey.zig").State = .{},
    /// The drop targets of `tkdnd::drop_target`.
    dnd: @import("dnd.zig").State = .{},
    /// The accent color of the system, when the backend gives one. The themes do not use it yet.
    accent: ?geom.Color = null,
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
    /// The grab of `grab`, and the tooltips of `ztk::tooltip` by widget path (owned).
    grab: @import("grab.zig").State = .{},
    tip: @import("grab.zig").Tip = .{},
    /// The open list of a `ttk::combobox`.
    popdown: @import("ttk/combobox.zig").Popdown = .{},
    /// The first menu of the posted chain of drawn menus.
    menu_root: ?*Widget = null,
    /// The toplevel that shows the posted chain.
    menu_top: ?*Widget = null,
    /// The menus of the last closed chain during their close move.
    menu_fade: @import("widgets/menudraw.zig").Fade = .{},
    /// The menu button that posted the chain, or null.
    menu_button: ?*Widget = null,
    /// The popup windows of the posted chain, for a backend with `Platform.popups`.
    menu_pops: @import("widgets/menupop.zig").Pops = .{},
    /// The atlas takes that the surface of the window of "." has.
    atlas_seen: u32 = 0,
    /// The menu widget of each native menu id, and the next id.
    menu_ids: std.AutoHashMapUnmanaged(u32, *Widget) = .empty,
    menu_next: u32 = 1,
    tooltips: std.StringHashMapUnmanaged([]u8) = .empty,
    /// The browser build: the text of a file of the page by its name, or null.
    virtual_file: ?*const fn (name: []const u8) ?[]const u8 = null,
    /// The toplevels other than ".", oldest first.
    tops: std.ArrayListUnmanaged(*Widget) = .empty,
    /// The images of `image create photo`.
    images: @import("image.zig").Registry = .{},

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
        fonts.system = opts.platform.textSystem();
        errdefer fonts.deinit();
        const rc = try gpa.dupe(u8, opts.root_class);
        errdefer gpa.free(rc);
        const an = try gpa.dupe(u8, opts.app_name);
        errdefer gpa.free(an);
        // The last step that can fail, so this copy needs no cleanup.
        const root_dir: ?[]const u8 = if (opts.style_root) |r| try gpa.dupe(u8, r) else null;
        app.* = .{ .gpa = gpa, .it = it, .root_class = rc, .app_name = an, .platform = opts.platform, .loop = undefined, .err_output = opts.err_output, .styles = style_mod.StyleSet.init(gpa), .io = opts.io, .on_exit = opts.on_exit, .hotkeys_allowed = opts.hotkeys, .animations = opts.animations, .start_us = opts.start_us, .compact_threshold = opts.compact_threshold, .fonts = fonts, .atlas = atlas_mod.Atlas.init(gpa), .bindings = bind.Table.init(gpa) };
        app.env.dark = opts.dark;
        // With no --dark, the scheme follows the system when the backend gives it.
        if (!opts.dark) app.followSystem();
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
            app.window.?.render.store(app.render, .release);
            if (app.render.mode == .threaded) {
                const spare = try render_thread.RenderThread.init(gpa, app.render.io, .threaded, idle_target);
                app.render_pool.append(gpa, spare) catch spare.deinit();
            }
        }
        _ = try app.styles.add(.base, "base", @embedFile("themes/base.css"));
        app.theme_sheet = try app.styles.add(.theme, "modern", @embedFile("themes/modern.css"));
        app.platform_sheet = try app.addPlatformSheet();
    }

    /// The platform sheet of the modern theme: the native look of the
    /// platform (Fluent on Windows), or the sheet of Linux.
    fn addPlatformSheet(app: *App) !u32 {
        const look = app.platform.nativeLook() orelse "";
        if (std.mem.eql(u8, look, "windows")) return app.styles.add(.platform, "fluent-windows", @embedFile("themes/fluent-windows.css"));
        return app.styles.add(.platform, "modern-linux", @embedFile("themes/modern-linux.css"));
    }

    /// Sets `--system-accent` to the accent of the system, in a sheet of
    /// its own that a change of the accent replaces.
    fn setAccentSheet(app: *App, accent: ?geom.Color) void {
        if (app.accent_sheet != 0) app.styles.remove(app.accent_sheet);
        app.accent_sheet = 0;
        const c = accent orelse return;
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, ":root {{ --system-accent: #{x:0>2}{x:0>2}{x:0>2}; }}", .{ c.r, c.g, c.b }) catch return;
        app.accent_sheet = app.styles.add(.platform, "system-accent", text) catch 0;
    }

    /// Changes the theme sheets to the classic look or the modern look.
    pub fn setLook(app: *App, classic: bool) !void {
        if (classic == app.classic_look) return;
        if (app.theme_sheet != 0) app.styles.remove(app.theme_sheet);
        if (app.platform_sheet != 0) app.styles.remove(app.platform_sheet);
        app.theme_sheet = 0;
        app.platform_sheet = 0;
        app.classic_look = classic;
        if (classic) {
            app.theme_sheet = try app.styles.add(.theme, "classic", @embedFile("themes/classic.css"));
        } else {
            app.theme_sheet = try app.styles.add(.theme, "modern", @embedFile("themes/modern.css"));
            app.platform_sheet = try app.addPlatformSheet();
        }
    }

    fn idleDraw(_: *anyopaque, _: *const scene_mod.Frame) anyerror!void {}

    /// The target of a render thread in the pool. It draws nothing.
    pub const idle_target: render_thread.Target = .{ .ctx = @ptrCast(@constCast(&max_frame)), .draw = idleDraw };

    /// A render thread for a new window: one from the pool, or a new one.
    pub fn takeRender(app: *App, mode: render_thread.Mode, target: render_thread.Target) !*render_thread.RenderThread {
        if (mode == .threaded) if (app.render_pool.pop()) |r| {
            r.retarget(target);
            return r;
        };
        return render_thread.RenderThread.init(app.gpa, app.render.io, mode, target);
    }

    /// Gives the render thread of a closed window back to the pool, or ends it.
    pub fn giveRender(app: *App, r: *render_thread.RenderThread) void {
        if (r.mode == .threaded and app.render_pool.items.len < 4 and !app.closing) {
            r.retarget(idle_target);
            app.render_pool.append(app.gpa, r) catch r.deinit();
            return;
        }
        r.deinit();
    }

    pub fn deinit(app: *App) void {
        app.closing = true;
        app.dbg.deinit(app.gpa);
        // The render thread draws no held frame into a window that goes away.
        if (app.render_ready) {
            if (app.window) |win| win.render.store(null, .release);
            app.render.retarget(idle_target);
        }
        @import("widgets/menupop.zig").dropAll(app);
        if (app.root) |r| widget.destroy(r);
        // A widget that has no root (a failed init) still needs a free.
        // The window goes away here, after the render thread finished its frames.
        app.sweepAll();
        if (app.render_ready) {
            if (app.window) |win| win.render.store(null, .release);
            app.render.deinit();
        }
        app.render_ready = false;
        for (app.render_pool.items) |r| r.deinit();
        app.render_pool.deinit(app.gpa);
        app.widgets.deinit(app.gpa);
        app.menu_ids.deinit(app.gpa);
        app.classes.deinit(app.gpa);
        app.clipboard.deinit(app.gpa);
        app.named_fonts.deinit(app.gpa);
        app.option_db.deinit(app.gpa);
        for (app.virtual_events.items) |d| bind.freeVirtual(app.gpa, d);
        app.virtual_events.deinit(app.gpa);
        app.text_input.deinit(app.gpa);
        app.trays.deinit(app);
        app.hotkeys.deinit(app);
        app.dnd.deinit(app);
        while (app.handles) |h| {
            app.handles = h.next;
            app.gpa.destroy(h);
        }
        if (app.it.user == @as(?*anyopaque, app)) app.it.user = null;
        app.loop.deinit();
        app.styles.deinit();
        app.ttk.deinit(app.gpa);
        app.bindings.deinit();
        app.anims.deinit(app.gpa);
        anim.deinit(app);
        app.opt_anims.deinit(app.gpa);
        app.images.deinit(app.gpa);
        app.fonts.deinit();
        app.atlas.deinit();
        app.wm.deinit(app.gpa);
        if (app.style_root) |r| app.gpa.free(r);
        app.events.deinit(app.gpa);
        app.tops.deinit(app.gpa);
        @import("grab.zig").deinit(app);
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
    /// A path of a mount of ztcl, such as `//zipfs:/app/a.css`, comes from the mount.
    pub fn readFile(app: *App, path: []const u8, a: std.mem.Allocator) ![]u8 {
        // The browser build has no files: the page gives each style sheet by its name.
        if (comptime @import("builtin").os.tag == .freestanding) {
            const f = app.virtual_file orelse return error.NoIo;
            const text = f(std.fs.path.basename(path)) orelse return error.FileNotFound;
            return a.dupe(u8, text);
        }
        // An app in one file (`appbin.zig`) has its style sheets in its payload.
        if (ztcl.vfs.isOurs(path)) {
            const hit = (ztcl.vfs.find(app.it, path) catch return error.FileNotFound) orelse return error.FileNotFound;
            return a.dupe(u8, ztcl.vfs.read(app.it, hit, "read", path) catch return error.FileNotFound);
        }
        const io = app.io orelse return error.NoIo;
        const root = app.style_root orelse return error.NoIo;
        const dir = std.Io.Dir.cwd();
        const real_root = try dir.realPathFileAlloc(io, root, a);
        const real = try dir.realPathFileAlloc(io, path, a);
        const inside = real.len > real_root.len and std.mem.startsWith(u8, real, real_root) and std.fs.path.isSep(real[real_root.len]);
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

    /// Reads the dark mode and the accent color of the system, and restyles
    /// each widget when the scheme changed.
    pub fn followSystem(app: *App) void {
        const a = app.platform.appearance() orelse return;
        const same_accent = if (app.accent) |x| (if (a.accent) |y| x.r == y.r and x.g == y.g and x.b == y.b else false) else a.accent == null;
        app.accent = a.accent;
        if (!same_accent) {
            app.setAccentSheet(a.accent);
            if (a.dark == app.env.dark) {
                if (app.root) |r| r.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
                for (app.tops.items) |t| t.invalidate(.{ .style = true, .measure = false, .layout = false, .paint = true });
                return;
            }
        }
        if (a.dark == app.env.dark) return;
        app.env.dark = a.dark;
        app.styles.generation +%= 1;
        if (app.root) |r| r.invalidate(.{ .style = true, .measure = true, .layout = true, .paint = true });
        for (app.tops.items) |t| t.invalidate(.{ .style = true, .measure = true, .layout = true, .paint = true });
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
        // A posted drawn menu gets the keys, as the focus of Tk goes to a posted menu.
        if (app.menu_root) |m| if (m.alive()) return m;
        if (app.focus.current) |c| if (c.alive()) return c;
        return app.root;
    }

    /// Asks the backend for one `frame` event, unless one is pending.
    /// The data of a toplevel other than ".", or null.
    pub fn topOf(app: *App, w: *const Widget) ?*Top {
        _ = app;
        if (w.class != &@import("widgets/toplevel.zig").class) return null;
        return @ptrCast(@alignCast(w.data orelse return null));
    }

    /// The platform window of a toplevel.
    pub fn winOf(app: *App, top: *const Widget) ?*platform_mod.Window {
        if (app.topOf(top)) |t| return t.win;
        if (top == app.root) return app.window;
        return null;
    }

    pub fn renderOf(app: *App, top: *const Widget) *render_thread.RenderThread {
        if (app.topOf(top)) |t| return t.render;
        return app.render;
    }

    pub fn wmOf(app: *App, top: *const Widget) *wm_mod.State {
        if (app.topOf(top)) |t| return &t.wm;
        return &app.wm;
    }

    /// The toplevel of a platform window, or null.
    pub fn topOfWindow(app: *App, win: *const platform_mod.Window) ?*Widget {
        if (app.window == win) return app.root;
        for (app.tops.items) |t| if (app.topOf(t)) |d| {
            if (d.win == win) return t;
        };
        return null;
    }

    /// Asks the backend for one `frame` event for each window, unless one is pending.
    pub fn requestFrame(app: *App) void {
        if (!app.frame_requested) if (app.window) |win| {
            app.frame_requested = true;
            app.platform.requestFrame(win);
        };
        for (app.tops.items) |t| if (app.topOf(t)) |d| {
            if (!d.frame_requested) {
                d.frame_requested = true;
                app.platform.requestFrame(d.win);
            }
        };
    }

    pub fn frameError(app: *App, e: anyerror) void {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "ztk: frame failed: {s}\n", .{@errorName(e)}) catch return;
        app.writeError(msg);
    }

    /// Asks the backend for a window size, and takes the size at once when
    /// the backend gives it at once.
    pub fn setWindowSize(app: *App, requested: geom.Size) void {
        const root = app.root orelse return;
        app.setTopSize(root, requested);
    }

    /// Asks the backend for a size of the window of a toplevel, and takes the size at once when
    /// the backend gives it at once.
    pub fn setTopSize(app: *App, top: *Widget, requested: geom.Size) void {
        const win = app.winOf(top) orelse return;
        const size: geom.Size = .{ .w = std.math.clamp(requested.w, 1, max_window), .h = std.math.clamp(requested.h, 1, max_window) };
        app.platform.vtable.requestSize(app.platform.ptr, win, size);
        if (win.size.w != top.geom.w or win.size.h != top.geom.h) {
            top.geom = .{ .x = 0, .y = 0, .w = win.size.w, .h = win.size.h };
            top.invalidate(.{ .style = false, .measure = false, .layout = true, .paint = true });
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
        // A child toplevel has its own window and its own scene.
        for (w.children.items) |c| if (!c.isToplevel()) try app.paintNode(c, b);
        if (w.class.overlay) |f| try f(w, b);
    }

    /// Paints the quads of one widget. A widget with an animation of its
    /// paint (a transition, a keyframe animation, a color of `ztk::animate`,
    /// or the move of a part) is painted for each stop of the animation,
    /// and the frame gets each list of quads, so the render thread can
    /// move the quads for the time that it draws. When the lists differ in
    /// their count, the widget is painted once for the time of the frame.
    fn paintOwn(app: *App, w: *widget.Widget, b: *scene_mod.Builder, f: PaintFn) anyerror!void {
        if (app.anim_frame == null) return f(w, b);
        const now = app.anim_frame.?.time_us;
        if (anim.keyOf(app, w)) |k| {
            if (!k.done and k.offsets.len >= 2) {
                const sp = k.spec.spec;
                const delay = @as(i64, sp.delay_ms) * 1000;
                const tmpl: scene_mod.FrameAnim = .{
                    .first = 0,
                    .count = 0,
                    .from = 0,
                    .start_us = k.start_us,
                    .delay_us = delay,
                    .len_us = @max(sp.totalUs() - delay, 1),
                    .timing = sp.timing,
                    .iterations = k.spec.count,
                    .direction = @fromBackingInt(@intCast(@backingInt(k.spec.direction))),
                    .fill_backwards = k.spec.fill == .backwards or k.spec.fill == .both,
                    .fill_forwards = k.spec.fill == .forwards or k.spec.fill == .both,
                    .base = true,
                };
                // The stops, then the computed style for the base set.
                const Stops = struct {
                    k: *const anim.KeyAnim,
                    w: *widget.Widget,
                    fn set(a: *App, ctx: *const anyopaque, i: ?usize) void {
                        const c: *const @This() = @ptrCast(@alignCast(ctx));
                        const idx = i orelse {
                            a.paint_override = null;
                            return;
                        };
                        a.paint_override = .{ .widget = c.w, .style = if (idx < c.k.stops.len) &c.k.stops[idx] else &c.w.style };
                    }
                };
                const ctx: Stops = .{ .k = k, .w = w };
                if (try app.paintStops(w, b, f, k.stops.len + 1, .{ .ctx = &ctx, .set = Stops.set }, k.offsets, tmpl)) return;
                return f(w, b);
            }
        }
        if (anim.transitionOf(app, w)) |a| {
            if (a.layout) return f(w, b);
            // One timing moves all quads: the property with the longest time.
            var spec: style_mod.TransSpec = .{};
            for (a.spec.props) |p| if (p.active() and p.totalUs() > spec.totalUs()) {
                spec = p;
            };
            const delay = @as(i64, spec.delay_ms) * 1000;
            const tmpl: scene_mod.FrameAnim = .{ .first = 0, .count = 0, .from = 0, .start_us = a.start_us, .delay_us = delay, .len_us = spec.totalUs() - delay, .timing = spec.timing };
            const Two = struct {
                a: *const anim.Anim,
                w: *widget.Widget,
                fn set(ap: *App, ctx: *const anyopaque, i: ?usize) void {
                    const c: *const @This() = @ptrCast(@alignCast(ctx));
                    const idx = i orelse {
                        ap.paint_override = null;
                        return;
                    };
                    ap.paint_override = .{ .widget = c.w, .style = if (idx == 0) &c.a.from else &c.a.to };
                }
            };
            const ctx: Two = .{ .a = a, .w = w };
            if (try app.paintStops(w, b, f, 2, .{ .ctx = &ctx, .set = Two.set }, &.{ 0, 1 }, tmpl)) return;
            return f(w, b);
        }
        if (animate_mod.paintMove(app, w, now)) |m| {
            // The quads move with the progress, so the paint now and the paint at the end
            // give each other time, by a line through both.
            const End = struct {
                style: style_mod.Style,
                w: *widget.Widget,
                fn set(ap: *App, ctx: *const anyopaque, i: ?usize) void {
                    const c: *const @This() = @ptrCast(@alignCast(ctx));
                    ap.paint_override = if (i != null and i.? == 1) .{ .widget = c.w, .style = &c.style } else null;
                }
            };
            const ctx: End = .{ .style = m.end, .w = w };
            if (try app.paintStops(w, b, f, 2, .{ .ctx = &ctx, .set = End.set }, &.{ m.now, 1 }, m.anim)) return;
            return f(w, b);
        }
        // The move of a part: paint once, and when one part moves, paint its end too.
        const first = b.scene.quads.items.len;
        app.part_move = .none;
        try f(w, b);
        const pm = app.part_move;
        app.part_move = .none;
        if (pm != .one) return;
        const m = pm.one;
        if (@abs(1 - m.now) < 1e-3) return;
        app.part_move = .blocked;
        defer app.part_move = .none;
        // The paint now again, and the paint at the end.
        const Phase = struct {
            fn set(ap: *App, _: *const anyopaque, i: ?usize) void {
                ap.part_end = i != null and i.? == 1;
            }
        };
        b.scene.quads.shrinkRetainingCapacity(first);
        const ok = try app.paintStops(w, b, f, 2, .{ .ctx = app, .set = Phase.set }, &.{ m.now, 1 }, m.anim);
        if (!ok) try f(w, b);
    }

    pub const PaintFn = *const fn (w: *widget.Widget, b: *scene_mod.Builder) anyerror!void;

    pub const Stage = struct {
        ctx: *const anyopaque,
        /// Sets the state of the paint of set i, or puts the state back for null.
        set: *const fn (app: *App, ctx: *const anyopaque, i: ?usize) void,
    };

    /// Paints a widget once for each set of an animation, and adds the
    /// lists and the animation to the frame. The last set stays in the
    /// scene. `tmpl` gives the timing. Returns false, with no quad added,
    /// when the sets differ in their count of quads.
    fn paintStops(app: *App, w: *widget.Widget, b: *scene_mod.Builder, f: PaintFn, sets: usize, stage: Stage, offsets: []const f32, tmpl: scene_mod.FrameAnim) !bool {
        const fr = app.anim_frame.?;
        const quads = &b.scene.quads;
        const first = quads.items.len;
        const mark = fr.anim_quads.items.len;
        const dmark = fr.drags.items.len;
        const rmark = fr.drag_rects.items.len;
        defer stage.set(app, stage.ctx, null);
        var count: ?usize = null;
        var k: usize = 0;
        while (k < sets) : (k += 1) {
            stage.set(app, stage.ctx, k);
            // Only the drags of the last paint stay.
            fr.drags.shrinkRetainingCapacity(dmark);
            fr.drag_rects.shrinkRetainingCapacity(rmark);
            try f(w, b);
            const n = quads.items.len - first;
            if (count == null) count = n;
            if (n != count.? or n == 0) {
                fr.anim_quads.shrinkRetainingCapacity(mark);
                fr.drags.shrinkRetainingCapacity(dmark);
                fr.drag_rects.shrinkRetainingCapacity(rmark);
                quads.shrinkRetainingCapacity(first);
                return false;
            }
            try fr.anim_quads.appendSlice(app.gpa, quads.items[first..]);
            if (k + 1 < sets) quads.shrinkRetainingCapacity(first);
        }
        const off_at = fr.anim_offsets.items.len;
        try fr.anim_offsets.appendSlice(app.gpa, offsets);
        var a = tmpl;
        a.first = @intCast(first);
        a.count = @intCast(count.?);
        a.from = @intCast(mark);
        a.stops = @intCast(offsets.len);
        a.offsets = @intCast(off_at);
        try fr.anims.append(app.gpa, a);
        return true;
    }

    /// Adds a drag of the quads from `first` to the end of the scene to the
    /// frame, so the render thread moves them with the pointer. `base`,
    /// `lo`, and `hi` are logical pixels of the window. See `scene.FrameDrag`.
    pub fn addDrag(app: *App, b: *scene_mod.Builder, first: usize, axis: u1, stretch: bool, base: f32, lo: f32, hi: f32) !void {
        return app.addDragGain(b, first, axis, stretch, base, lo, hi, 1);
    }

    /// `addDrag` with a gain: the quads move by `gain` times the distance of the pointer.
    pub fn addDragGain(app: *App, b: *scene_mod.Builder, first: usize, axis: u1, stretch: bool, base: f32, lo: f32, hi: f32, gain: f32) !void {
        const fr = app.anim_frame orelse return;
        const quads = b.scene.quads.items;
        if (first >= quads.len) return;
        const at = fr.drag_rects.items.len;
        for (quads[first..]) |q| try fr.drag_rects.append(app.gpa, q.rect);
        try fr.drags.append(app.gpa, .{ .first = @intCast(first), .count = @intCast(quads.len - first), .rects = @intCast(at), .axis = axis, .stretch = stretch, .base = base, .lo = lo, .hi = hi, .scale = b.scale, .gain = gain });
    }

    /// Notes the move of a part in the paint of a widget, for `paintOwn`.
    pub fn notePartMove(app: *App, start_us: i64, spec: style_mod.TransSpec, now_p: f32) void {
        const delay = @as(i64, spec.delay_ms) * 1000;
        const a: scene_mod.FrameAnim = .{ .first = 0, .count = 0, .from = 0, .start_us = start_us, .delay_us = delay, .len_us = @max(spec.totalUs() - delay, 1), .timing = spec.timing };
        switch (app.part_move) {
            .none => app.part_move = .{ .one = .{ .anim = a, .now = now_p } },
            .one => |o| if (o.anim.start_us != a.start_us or o.anim.len_us != a.len_us or o.anim.delay_us != a.delay_us or !std.meta.eql(o.anim.timing, a.timing)) {
                app.part_move = .mixed;
            },
            .mixed, .blocked => {},
        }
    }

    /// Delivers Map, Unmap, and Configure events for each widget whose
    /// mapped flag or geometry changed since the last report.
    fn reportGeometry(app: *App, w: *widget.Widget) void {
        if (!w.alive()) return;
        if (w.mapped != w.cfg_mapped) {
            w.cfg_mapped = w.mapped;
            var ev: bind.WidgetEvent = .{ .type = if (w.mapped) .map else .unmap, .widget = w };
            bind.deliver(app, &ev);
            // A window that maps becomes visible, as X11 reports it.
            if (w.mapped and w.alive()) {
                var vis: bind.WidgetEvent = .{ .type = .visibility, .widget = w };
                bind.deliver(app, &vis);
            }
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
        const win = app.winOf(top) orelse return false;
        const wms = app.wmOf(top);
        const rend = app.renderOf(top);
        const now = app.platform.nowUs();
        const opt_running = @import("animate.zig").tick(app, now);
        const animating = anim.tick(app, now) or opt_running;
        // A part that moved in the last frame paints again when the time moved on.
        if (app.anim_more and now != app.anim_more_us) top.dirty.paint = true;
        if (!top.dirty.any() and !app.style_pending and app.styles.generation == app.style_gen) return false;
        const wall = &app.wall;
        const wall0 = wall.*();
        app.stats.begin(.style, wall0);
        app.restyle();
        app.stats.end(.style, wall.*());
        app.stats.begin(.layout, wall.*());
        _ = layout.run(top);
        app.stats.end(.layout, wall.*());
        if (wms.geometry == null and layout.propagates(top)) {
            const m = wms.minsize;
            const x = wms.maxsize;
            const want: geom.Size = .{
                .w = std.math.clamp(top.req.w, @max(m.w, 1), @max(x.w, m.w, 1)),
                .h = std.math.clamp(top.req.h, @max(m.h, 1), @max(x.h, m.h, 1)),
            };
            if (want.w != wms.last_req.w or want.h != wms.last_req.h) {
                wms.last_req = want;
                app.setTopSize(top, want);
                _ = layout.run(top);
            }
        }
        top.dirty.style = false;
        app.reportGeometry(top);
        // A Configure or Map binding can delete the toplevel.
        if (!top.alive()) return false;
        if (wms.withdrawn or !top.dirty.paint) {
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
        const fr = rend.back();
        fr.reset(app.gpa);
        fr.scene.reset(@max(dw, 1), @max(dh, 1));
        fr.scene.clear = colorF(top.style.background);
        var b = scene_mod.Builder.init(app.gpa, &fr.scene, scale);
        fr.time_us = now;
        app.anim_more = false;
        app.anim_frame = fr;
        defer app.anim_frame = null;
        try app.paintNode(top, &b);
        try @import("widgets/menudraw.zig").paintBar(app, top, &b);
        try @import("ttk/combobox.zig").paintPopdown(app, top, &b);
        try @import("widgets/menudraw.zig").paintPosted(app, top, &b);
        try @import("grab.zig").paintTip(app, top, &b);
        const seen = if (app.topOf(top)) |d| &d.atlas_seen else &app.atlas_seen;
        try app.atlas.takePatchesFor(app.gpa, &fr.patches, seen);
        app.stats.end(.paint, wall.*());
        app.stats.begin(.render, wall.*());
        rend.submit();
        @import("widgets/menupop.zig").paintAll(app, top);
        app.stats.end(.render, wall.*());
        top.dirty = widget.Dirty.none;
        app.anim_more_us = now;
        app.frames += 1;
        if (app.dbg.trace.mask != 0) @import("debug.zig").frame(app, top, wall.*() - wall0);
        if (app.frames == 1) app.stats.first_frame_us = wall.*() - app.start_us;
        app.stats.frameDone(wall.*());
        // An animation asks for the next frame.
        // The time must move on, so a frame at the same time (a manual clock) does not loop.
        if ((animating or app.anim_more) and now != app.anim_requested_us) {
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

    /// Waits until each render thread showed its submitted frames.
    pub fn flushRender(app: *App) void {
        if (app.render_ready) app.render.flush();
        for (app.tops.items) |t| if (app.topOf(t)) |d| d.render.flush();
    }

    /// The scene of the last frame that was drawn. In threaded mode, call it after `update`.
    pub fn lastScene(app: *App) *const scene_mod.Scene {
        return &app.render.lastFrame().scene;
    }

    /// Runs frames and passes until no work is left, as `update` needs.
    pub fn flush(app: *App) ztcl.Error!void {
        defer @import("textinput.zig").sync(app);
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            const root = app.root orelse return;
            var drew = app.frame(root) catch |e| blk: {
                app.frameError(e);
                break :blk false;
            };
            var k: usize = 0;
            while (k < app.tops.items.len) : (k += 1) {
                const t = app.tops.items[k];
                if (app.frame(t) catch false) drew = true;
            }
            const worked = try app.pass();
            if (!drew and !worked) return;
        }
    }

    /// True when a wait can end: a timer, an idle entry, or a live backend exists.
    pub fn canWait(app: *App) bool {
        return app.platform.live or app.loop.nextTimeoutUs() != null;
    }

    pub fn handleEvent(app: *App, ev: event.Event) void {
        if (ev == .app_command) return app.appCommand(ev.app_command.command);
        // A window that is gone has no events. Compare the pointer only.
        if (@import("widgets/menupop.zig").handleEvent(app, ev)) return;
        const top = app.topOfWindow(ev.window() orelse return) orelse return;
        switch (ev) {
            .resize => |r| {
                // A backend can report any size.
                top.geom.w = std.math.clamp(r.size.w, 1, max_window);
                top.geom.h = std.math.clamp(r.size.h, 1, max_window);
                top.invalidate(.{ .style = false, .measure = false, .layout = true, .paint = true });
            },
            .close => app.closeTop(top),
            .frame => {
                if (app.topOf(top)) |d| d.frame_requested = false else app.frame_requested = false;
                _ = app.frame(top) catch |e| app.frameError(e);
            },
            .focus => |f| focus_mod.windowFocus(app, f.focused),
            .scale => top.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true }),
            .motion, .button, .leave, .key, .scroll, .preedit, .commit => dispatch.handleIn(app, ev, top),
            .appearance => app.followSystem(),
            .tray => |tr| @import("tray.zig").handleEvent(app, tr.id, tr.action),
            .hotkey => |hk| @import("hotkey.zig").handleEvent(app, hk.id),
            .drop => |dr| @import("dnd.zig").handleEvent(app, dr, top),
            .menu => |m| @import("widgets/menu.zig").handleEvent(app, m.menu, m.entry, m.action),
            .app_command => {},
        }
    }

    /// Runs the `WM_DELETE_WINDOW` script of a toplevel, or destroys it.
    fn closeTop(app: *App, top: *Widget) void {
        if (app.wmOf(top).delete_script) |script| {
            const copy = app.gpa.dupe(u8, script) catch return;
            defer app.gpa.free(copy);
            app.callback(copy);
        } else {
            widget.destroy(top);
        }
    }

    /// A command of the application menu, as Tk on macOS maps it to the script.
    fn appCommand(app: *App, cmd: event.AppCommand) void {
        const name = switch (cmd) {
            .about => "tkAboutDialog",
            .settings => "::tk::mac::ShowPreferences",
            .quit => "::tk::mac::Quit",
        };
        if (app.it.findCommand(name) != null) return app.callback(name);
        if (cmd != .quit) return;
        if (app.root) |r| if (r.alive()) app.closeTop(r);
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
                    else => it.fail("command returned bad code: {d}", .{@backingInt(it.ret_code)}),
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
